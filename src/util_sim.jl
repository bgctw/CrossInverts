"""
    gen_sim_sols_probs(; tools, psets, problemupdater, 
        solver = AutoTsit5(Rodas5()), kwargs_gen...)

Generates a function `sim_sols_probs(fixed, ranadd, ranmul, indiv, indiv_ranmul, indiv_ranadd)`
that updates and simulate the system (given with tools to `gen_sim_sols_probs`) by 
- for each individual i
  - update fixed parameters: fixed 
  - update ranadd parameters: ranadd .+ indiv_ranadd[:,i]
  - update ranmul parameters: ranmul .* indiv_ranmul[:,i]
  - update indiv_id parameters: indiv[:,i]
  - simulate the problem
- return a vector(n_indiv) of (;sol, problem_opt)

If non-optimized `p` or `u0` differ between individuals, they must already be
set in `tools[i_indiv].problem`.
"""
function gen_sim_sols_probs(;
        tools, psets, problemupdater, solver = AutoTsit5(Rodas5()), kwargs_gen...)
    fLogger = EarlyFilteredLogger(current_logger()) do log
        #@show log
        !(log.level == Logging.Warn && log.group == :integrator_interface)
    end
    n_indiv = length(tools)
    # see help on MTKHelpers.ODEProblemParSetterConcrete
    fbarrier = () -> let solver = solver,
        problems_indiv = map(t -> t.problem, tools),
        psets = map(get_concrete, psets), problemupdater = get_concrete(problemupdater),
        n_indiv = n_indiv,
        kwargs_gen = kwargs_gen,
        fLogger = fLogger
        #, psetci_u_PlantNP=psetci_u_PlantNP 
        kwargs_indiv_default = fill((), n_indiv)
        #
        (fixed, ranadd, ranmul, indiv, indiv_ranadd, indiv_ranmul;
        kwargs_indiv = kwargs_indiv_default, kwargs...) -> begin
            map(1:n_indiv) do i_indiv
                problem_opt = problems_indiv[i_indiv] # no need to copy, in update_statepar 
                # remake Dict not inferred yet: problem_opt = @inferred remake(problem_opt, fixed, psets.fixed)
                problem_opt = remake(problem_opt, fixed, psets.fixed)
                problem_opt = remake(problem_opt,
                    ranadd .+ indiv_ranadd[:, i_indiv], psets.ranadd)
                problem_opt = remake(problem_opt,
                    ranmul .* indiv_ranmul[:, i_indiv], psets.ranmul)
                problem_opt = remake(problem_opt, indiv[:, i_indiv], psets.indiv)
                # make sure to use problemupdater on the last update
                #problem_opt = @inferred problemupdater(problem_opt)
                problem_opt = problemupdater(problem_opt)
                #if !isempty(kwargs); problem_opt = remake(problem_opt; kwargs...); end
                #local parl = label_par(psetci, problem_opt.p) #@inferred label_par(psetci, problem_opt.p)
                #suppress does not work with MCMCThreads() sampling
                #sol = @suppress solve(problem_opt, solver, maxiters = 1e4)
                sol = with_logger(fLogger) do
                    sol = solve(problem_opt, solver;
                        kwargs_gen..., kwargs_indiv[i_indiv]..., kwargs...)
                end
                (; sol, problem_opt)
            end # map 1:n_indiv
        end # function  
    end # let
    sim_sols_probs = fbarrier()
    return sim_sols_probs
end

function gen_sim_sols(; kwargs...)
    sim_sols_probs = gen_sim_sols_probs(; kwargs...)
    gen_sim_sols(sim_sols_probs)
end

# feed a single poptl NamedTuple
# after calling sim_sols_probs, extract the sol component
function gen_sim_sols(sim_sols_probs)
    let sim_sols_probs = sim_sols_probs
        (poptl; kwargs...) -> begin
            res_sim = sim_sols_probs(poptl.fixed, poptl.ranadd, poptl.ranmul, poptl.indiv,
                poptl.indiv_ranadd, poptl.indiv_ranmul;
                kwargs...)
            map(x -> x.sol, res_sim)
        end
    end
end

function sample_random(inv_case::AbstractCrossInversionCase, ranadd, ranmul; scenario,
        rng::AbstractRNG = Random.default_rng())
    priors_random_dict = get_case_priors_random_dict(inv_case; scenario)
    priors_random = dict_to_cv(keys(ranmul), priors_random_dict)
    (; ranadd = ranmul .+ sample_ranaddef(rng, priors_random),
        ranmul = ranmul .* sample_ranmulef(rng, priors_random)) 
end

function sample_ranaddef(rng, priors_random)
    # Normal around 0
    gen = (begin
               dist_sigma = priors_random[kp]
               #σ = mean(dist_sigma)
               σ = rand(rng, dist_sigma)
               #dim_d = length(dist_sigma)
               len_σ = length(σ)
               dist = (len_σ == 1) ?
                      fit_mean_Σ(Normal, 0, σ) :
                      fit_mean_Σ(Normal, fill(0, len_σ), PDiagMat(σ .^ 2))
               r = rand(rng, dist)
               (kp, r)
           end
    for kp in keys(priors_random))
    ComponentVector(; gen...)
end

function sample_ranmulef(rng, priors_random)
    # LogNormal around 1
    gen = (begin
               dist_sigma = priors_random[kp]
               #σ = mean(dist_sigma)
               σ = rand(rng, dist_sigma)
               #dim_d = length(dist_sigma)
               len_σ = length(σ)
               dist = (len_σ == 1) ?
                      fit_mean_Σ(LogNormal, 1, σ) :
                      fit_mean_Σ(MvLogNormal, fill(1, len_σ), PDiagMat(σ .^ 2))
               r = rand(rng, dist)
               (kp, r)
           end
    for kp in keys(priors_random))
    ComponentVector(; gen...)
end
