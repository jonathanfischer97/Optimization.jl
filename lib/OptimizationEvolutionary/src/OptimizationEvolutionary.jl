module OptimizationEvolutionary

using Reexport
@reexport using Evolutionary, Optimization
using Optimization.SciMLBase

SciMLBase.allowsbounds(opt::Evolutionary.AbstractOptimizer) = true
SciMLBase.allowsconstraints(opt::Evolutionary.AbstractOptimizer) = true
SciMLBase.supports_opt_cache_interface(opt::Evolutionary.AbstractOptimizer) = true

decompose_trace(trace::Evolutionary.OptimizationTrace) = last(trace)
decompose_trace(trace::Evolutionary.OptimizationTraceRecord) = trace

#todo Make this work with user overloads which might now include x 
function Evolutionary.trace!(record::Dict{String, Any}, objfun, state, population,
        method::Evolutionary.AbstractOptimizer, options)
    record["x"] = population
end

function __map_optimizer_args(cache::OptimizationCache,
        opt::Evolutionary.AbstractOptimizer;
        callback = nothing,
        maxiters::Union{Number, Nothing} = nothing,
        maxtime::Union{Number, Nothing} = nothing,
        abstol::Union{Number, Nothing} = nothing,
        reltol::Union{Number, Nothing} = nothing,
        initial_population::Union{AbstractArray, Nothing} = nothing,
        kwargs...)
    mapped_args = (; kwargs...)

    if !isnothing(callback)
        mapped_args = (; mapped_args..., callback = callback)
    end

    if !isnothing(maxiters)
        mapped_args = (; mapped_args..., iterations = maxiters)
    end

    if !isnothing(maxtime)
        mapped_args = (; mapped_args..., time_limit = maxtime)
    end

    if !isnothing(abstol)
        mapped_args = (; mapped_args..., abstol = abstol)
    end

    if !isnothing(reltol)
        mapped_args = (; mapped_args..., reltol = reltol)
    end

    return Evolutionary.Options(; mapped_args...)
end

function SciMLBase.__solve(cache::OptimizationCache{
        F,
        RC,
        LB,
        UB,
        LC,
        UC,
        S,
        O,
        D,
        P,
        C,
}) where {
        F,
        RC,
        LB,
        UB,
        LC,
        UC,
        S,
        O <:
        Evolutionary.AbstractOptimizer,
        D,
        P,
        C,
}
    local x, cur, state

    if cache.data != Optimization.DEFAULT_DATA
        maxiters = length(cache.data)
    end

    cur, state = iterate(cache.data)

    # Internal callback function called on trace after every iteration 
    function _cb(trace)
        curr_u = decompose_trace(trace).metadata["x"][end]
        opt_state = Optimization.OptimizationState(;
            iter = decompose_trace(trace).iteration,
            u = curr_u,
            objective = x[1],
            original = trace)
        cb_call = cache.callback(opt_state, decompose_trace(trace).value...)
        if !(cb_call isa Bool)
            error("The callback should return a boolean `halt` for whether to stop the optimization process.")
        end
        cur, state = iterate(cache.data, state)
        cb_call
    end

    maxiters = Optimization._check_and_convert_maxiters(cache.solver_args.maxiters)
    maxtime = Optimization._check_and_convert_maxtime(cache.solver_args.maxtime)

    # Get OptimizationFunction
    f = cache.f

    # Define the loss function as closure, returns the value of the OptimizationFunction for θ
    _loss = function (θ)
        x = f(θ, cache.p, cur...)
        return x
    end

    # Retrieve keyword arguments for the optimizer
    opt_args = __map_optimizer_args(cache, cache.opt; callback = _cb, cache.solver_args...,
        maxiters = maxiters,
        maxtime = maxtime)

    # Extract initial_population from solver_args if provided
    initial_population = get(cache.solver_args, :initial_population, nothing)

    t0 = time()
    if isnothing(cache.lb) || isnothing(cache.ub)
        if !isnothing(f.cons)
            c = x -> (res = zeros(length(cache.lcons)); f.cons(res, x); res)
            cons = WorstFitnessConstraints(Float64[], Float64[], cache.lcons, cache.ucons,
                c)
            # Check if initial_population is provided from solver_args
            if isnothing(initial_population)
                opt_res = Evolutionary.optimize(_loss, cons, cache.u0, cache.opt, opt_args)
            else
                opt_res = Evolutionary.optimize(_loss, cons, cache.opt, initial_population, opt_args)
            end
            # opt_res = Evolutionary.optimize(_loss, cons, cache.u0, cache.opt, opt_args)
        else
            if isnothing(initial_population)
                opt_res = Evolutionary.optimize(_loss, cache.u0, cache.opt, opt_args)
            else
                opt_res = Evolutionary.optimize(_loss, cache.opt, initial_population, opt_args)
            end
            # opt_res = Evolutionary.optimize(_loss, cache.u0, cache.opt, opt_args)
        end
    else
        if !isnothing(f.cons)
            c = x -> (res = zeros(length(cache.lcons)); f.cons(res, x); res)
            cons = WorstFitnessConstraints(cache.lb, cache.ub, cache.lcons, cache.ucons, c)
        else
            cons = BoxConstraints(cache.lb, cache.ub)
        end

        if isnothing(initial_population)
            opt_res = Evolutionary.optimize(_loss, cons, cache.u0, cache.opt, opt_args)
        else
            opt_res = Evolutionary.optimize(_loss, cons, cache.opt, initial_population, opt_args)
        end
        # opt_res = Evolutionary.optimize(_loss, cons, cache.u0, cache.opt, opt_args)
    end
    t1 = time()
    opt_ret = Symbol(Evolutionary.converged(opt_res))
    stats = Optimization.OptimizationStats(; iterations = opt_res.iterations,
        time = t1 - t0, fevals = opt_res.f_calls)
    SciMLBase.build_solution(cache, cache.opt,
        Evolutionary.minimizer(opt_res),
        Evolutionary.minimum(opt_res); original = opt_res,
        retcode = opt_ret,
        stats = stats)
end

end
