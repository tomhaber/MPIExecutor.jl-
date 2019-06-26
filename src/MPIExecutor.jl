module MPIExecutor

using Serialization

import Base: size, get!

include("MPIUtils.jl")
include("RemoteFunction.jl")

export MPIPoolExecutor, shutdown!, @remote,
    submit!, run!, then!,
    fulfill!, whenall!, get!,
    run_broadcast!

struct WorkUnit
    f::RemoteFunction
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

    function MPIPoolExecutor(worker_count::Int64)
        start()
        prep_stop()

        slave_path = "$(join(split("$(@__FILE__)", '/')[1:end-1], "/"))/slave.jl"

        comm =
            if worker_count > 0
                MPI.Comm_spawn("julia", [slave_path], worker_count, MPI.COMM_WORLD)
            else
                MPI.COMM_WORLD
            end

        slaves = Int64[i-1 for i in 1:worker_count]

        new(slaves, copy(slaves), comm, 0, 0, WorkUnit[], Dict{Int64, WorkUnit}())
    end
end

include("Future.jl")

Base.size(pool::MPIPoolExecutor) = isempty(pool.slaves) ? 1 : length(pool.slaves)

function shutdown!(pool::MPIPoolExecutor)
    while !all_idle(pool)
        receive_any!(pool)
    end

    for worker in pool.slaves
        io = IOBuffer()
        MPI.Send(io.data[1:io.size], worker, 2, pool.comm)
    end

    if pool.comm !== MPI.COMM_WORLD
        MPI.Comm_free(pool.comm)
    end
end


function register!(pool::MPIPoolExecutor, expression::Expr)
    rid = (pool.identifier += 1)

    io = IOBuffer()
    serialize(io, rid)
    serialize(io, expression)

    buf = io.data[1:io.size]

    for worker in pool.slaves
        MPI.Send(buf, worker, 1, pool.comm)
    end

    rid
end

function submit!(pool::MPIPoolExecutor, f::RemoteFunction, args...)
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

    if isempty(pool.runnable) && length(pool.idle) == length(pool.slaves)
        true
    else
        false
    end
end

function receive_any!(pool::MPIPoolExecutor)
    result, s = MPI.Iprobe(MPI.ANY_SOURCE, 0, pool.comm)
    if result
        received_from = MPI.Get_source(s)
        count = MPI.Get_count(s, UInt8)
        recv_mesg = Array{UInt8}(undef, count)
        MPI.Recv!(recv_mesg, received_from, 0, pool.comm)
        io = IOBuffer(recv_mesg)
        tracker_id = deserialize(io)
        push!(pool.idle, received_from)
        fulfill!(pool.running[tracker_id].fut, deserialize(io))
        received_from
    end
end

function dispatch!(pool::MPIPoolExecutor, work::WorkUnit, worker)
    io = IOBuffer()

    tracker_id = (pool.tracker += 1)
    pool.running[tracker_id] = work
    serialize(io, tracker_id)
    serialize(io, work.args)

    id = work.f.remote_identifier
    MPI.Send(io.data[1:io.size], worker, 4 + id, pool.comm)
end

function run_broadcast!(pool::MPIPoolExecutor, f::RemoteFunction, args...)
    @assert all_idle(pool)

    all_futs = Future[]

    for worker in pool.idle
        t = WorkUnit(f, args, Future(pool))
        dispatch!(pool, t, worker)
        push!(all_futs, t.fut)
    end

    pool.idle = []

    whenall!(all_futs)
end

end # module
