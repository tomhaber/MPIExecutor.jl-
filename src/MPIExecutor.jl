module MPIExecutor

using Serialization
using MPI

import Base: size, get!

include("RemoteFunction.jl")
include("worker.jl")

macro prof(name::Symbol, ex)
	if true
			quote
					local elapsedtime = time_ns()
					local val = $(esc(ex))
					elapsedtime = time_ns() - elapsedtime
					println($(String(name))," ", elapsedtime/1e9)
					val
			end
	else
			quote
				$(esc(ex))
			end
	end
end

export MPIPoolExecutor, shutdown!, @remote,
    submit!, run!, run_until!, then!,
    fulfill!, whenall!, get!,
    run_broadcast!, main_worker

struct WorkUnit
    f::Function
    args::Tuple
    fut

    function WorkUnit(f, args, fut)
        new(f, args, fut)
    end
end

mutable struct MPIPoolExecutor
    slaves::Array{Int64,1}
    idle::Array{Int64,1}
    comm::MPI.Comm
    identifier::Int64
    tracker::Int64
    runnable::Array{WorkUnit,1}
    running::Dict{Int64, WorkUnit}

    function MPIPoolExecutor(comm::MPI.Comm=MPI.COMM_WORLD)
      worker_count = MPI.Comm_size(comm) - 1
      slaves = Int64[1:worker_count;]
      new(slaves, copy(slaves), comm, 0, 0, WorkUnit[], Dict{Int64, WorkUnit}())
    end
end

include("Future.jl")

Base.size(pool::MPIPoolExecutor) = isempty(pool.slaves) ? 1 : length(pool.slaves)

function shutdown!(pool::MPIPoolExecutor)
    while !all_idle(pool)
        wait_any!(pool)
    end

    for worker in pool.slaves
        io = IOBuffer()
        MPI.Send(io.data[1:io.size], worker, 2, pool.comm)
    end

    if pool.comm !== MPI.COMM_WORLD
        MPI.free(pool.comm)
    end
end

function MPIPoolExecutor(f::Function, ::Nothing=nothing)
    if !MPI.Initialized()
        MPI.Init()
    end

    @assert !MPI.Finalized()
    MPIPoolExecutor(f, MPI.COMM_WORLD)
end

function MPIPoolExecutor(f::Function, worker_count::Int64, comm=MPI.COMM_WORLD)
    if !MPI.Initialized()
        MPI.Init()
    end

    @assert !MPI.Finalized()

    if MPI.Comm_size(comm) <= worker_count
        additional_workers = worker_count - MPI.Comm_size(comm) + 1
        intercomm = MPI.Comm_spawn("julia", ["-e", "import MPIExecutor; MPIExecutor.main_worker()"], additional_workers, MPI.COMM_WORLD)
        comm = MPI.Intercomm_merge(intercomm, false)
    end

    @assert MPI.Comm_size(comm) == worker_count + 1
    MPIPoolExecutor(f, comm)
end

function MPIPoolExecutor(f::Function, comm::MPI.Comm)
    if MPI.Comm_rank(comm) == 0
        pool = MPIPoolExecutor(comm)

        try
        f(pool)
        finally
        shutdown!(pool)
        end
    else
        main_worker(comm)
    end
end

function is_anon_function(f::Function)
    t = typeof(f)
    tn = t.name
    if isdefined(tn, :mt)
        name = tn.mt.name
        mod = tn.module
        return mod === Main && # only Main
            t.super === Function && # only Functions
            unsafe_load(Base.unsafe_convert(Ptr{UInt8}, tn.name)) == UInt8('#') && # hidden type
            (!isdefined(mod, name) || t != typeof(getfield(mod, name))) # XXX: 95% accurate test for this being an inner function
            # TODO: more accurate test? (tn.name !== "#" name)
    end
    return false
end

register!(pool::MPIPoolExecutor, x::Function...) = map(f -> register!(pool, f), x)

function register!(pool::MPIPoolExecutor, f::Function)
    @assert is_anon_function(f)
    rid = (pool.identifier += 1)

    io = IOBuffer()
    serialize(io, rid)
    serialize(io, f)

    buf = io.data[1:io.size]

    for worker in pool.slaves
        MPI.Send(buf, worker, 1, pool.comm)
    end

    RemoteFunction(rid, f)
end

function submit!(pool::MPIPoolExecutor, f::Function, args...)
    t = WorkUnit(f, args, Future(pool))
    push!(pool.runnable, t)
    t.fut
end

function all_idle(pool::MPIPoolExecutor)
    length(pool.idle) == length(pool.slaves)
end

function run!(pool::MPIPoolExecutor)
    if isempty(pool.slaves) && !isempty(pool.runnable)
        todo = pop!(pool.runnable)
        fulfill!(todo.fut, todo.f(todo.args...))
    else
        while !isempty(pool.runnable) && !isempty(pool.idle)
            todo = pop!(pool.runnable)
            dispatch!(pool, todo, pop!(pool.idle))
        end

        receive_any!(pool)
    end

    isempty(pool.runnable) && all_idle(pool)
end

function run_until!(pool::MPIPoolExecutor)
    run_until!(pool, () -> false)
end

function run_until!(pool::MPIPoolExecutor, pull::Function)
    if isempty(pool.slaves)
        # master-only mode
        if isempty(pool.runnable) && ! pull()
            return nothing
        end

        @assert !isempty(pool.runnable)
        todo = pop!(pool.runnable)
        fulfill!(todo.fut, todo.f(todo.args...))
    else
        while !isempty(pool.runnable) && !isempty(pool.idle)
            todo = pop!(pool.runnable)
            dispatch!(pool, todo, pop!(pool.idle))
        end

        while !isempty(pool.idle) && pull()
            @assert !isempty(pool.runnable)
            todo = pop!(pool.runnable)
            dispatch!(pool, todo, pop!(pool.idle))
        end

        if !all_idle(pool)
            wait_any!(pool)
        end
    end
end

function handle_recv!(pool::MPIPoolExecutor, s::MPI.Status)
    received_from = MPI.Get_source(s)
    count = MPI.Get_count(s, UInt8)
    recv_mesg = Array{UInt8}(undef, count)
    MPI.Recv!(recv_mesg, received_from, 0, pool.comm)
    io = IOBuffer(recv_mesg)
    tracker_id = deserialize(io)
    push!(pool.idle, received_from)
    fulfill!(pool.running[tracker_id].fut, deserialize(io))
end

function receive_any!(pool::MPIPoolExecutor)
    result, s = MPI.Iprobe(MPI.MPI_ANY_SOURCE, 0, pool.comm)
    if result
      handle_recv!(pool, s)
    else
      nothing
    end
end

function wait_any!(pool::MPIPoolExecutor)
    s = MPI.Probe(MPI.MPI_ANY_SOURCE, 0, pool.comm)
    handle_recv!(pool, s)
end

function dispatch!(pool::MPIPoolExecutor, work::WorkUnit, worker)
    io = IOBuffer()

    tracker_id = (pool.tracker += 1)
    pool.running[tracker_id] = work
    serialize(io, work.f)
    serialize(io, tracker_id)
    serialize(io, work.args)

    MPI.Send(io.data[1:io.size], worker, 3, pool.comm)
end

function run_broadcast!(pool::MPIPoolExecutor, f::Function, args...)
    @assert all_idle(pool)

    if !isempty(pool.slaves)
      all_futs = Future[]

      for worker in pool.idle
          t = WorkUnit(f, args, Future(pool))
          dispatch!(pool, t, worker)
          push!(all_futs, t.fut)
      end

      pool.idle = []

      whenall!(all_futs)
    else
      Future(pool, Some(f(args...)))
    end
end

end # module
