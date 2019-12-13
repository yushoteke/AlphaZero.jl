"""
Utilities to evaluate players against one another.
"""
module Benchmark

import ..Util.@unimplemented
import ..Env, ..AbstractPlayer, ..AbstractNetwork
import ..MCTS, ..MctsParams, ..MctsPlayer, ..pit
import ..ColorPolicy, ..ALTERNATE_COLORS
import ..MinMax, ..GI

using ProgressMeter
using Distributions: Categorical

struct DuelOutcome
  player :: String
  baseline :: String
  avgz :: Float64
  rewards :: Vector{Float64}
  time :: Float64
end

const Report = Vector{DuelOutcome}

abstract type Player end

function instantiate(player::Player, nn)
  @unimplemented
end

function name(::Player) :: String
  @unimplemented
end

struct Duel
  num_games :: Int
  reset_every :: Union{Nothing, Int}
  color_policy :: ColorPolicy
  player :: Player
  baseline :: Player
  function Duel(player, baseline;
      num_games, reset_every=nothing, color_policy=ALTERNATE_COLORS)
    return new(num_games, reset_every, color_policy, player, baseline)
  end
end

function run(env::Env, duel::Duel, progress=nothing)
  player = instantiate(duel.player, env.bestnn)
  baseline = instantiate(duel.baseline, env.bestnn)
  let games = Vector{Float64}(undef, duel.num_games)
    avgz, time = @timed begin
      pit(
        baseline, player, duel.num_games,
        reset_every=duel.reset_every, color_policy=duel.color_policy) do i, z
          games[i] = z
          isnothing(progress) || next!(progress)
      end
    end
    return DuelOutcome(
      name(duel.player), name(duel.baseline), avgz, games, time)
  end
end

#####
##### Statistics for games with ternary rewards
#####

struct TernaryOutcomeStatistics
  num_won  :: Int
  num_draw :: Int
  num_lost :: Int
end

function TernaryOutcomeStatistics(rewards::AbstractVector{<:Number})
  num_won  = count(==(1), rewards)
  num_draw = count(==(0), rewards)
  num_lost = count(==(-1), rewards)
  @assert num_won + num_draw + num_lost == length(rewards)
  return TernaryOutcomeStatistics(num_won, num_draw, num_lost)
end

function TernaryOutcomeStatistics(outcome::DuelOutcome)
  return TernaryOutcomeStatistics(outcome.rewards)
end

#####
##### Standard players
#####

struct MctsRollouts <: Player
  params :: MctsParams
end

name(::MctsRollouts) = "MCTS Rollouts"

function instantiate(p::MctsRollouts, nn::AbstractNetwork{G}) where G
  params = MctsParams(p.params,
    num_workers=1,
    use_gpu=false)
  return MctsPlayer(MCTS.RolloutOracle{G}(), params)
end

struct Full <: Player
  params :: MctsParams
end

name(::Full) = "AlphaZero"

instantiate(p::Full, nn) = MctsPlayer(nn, p.params)

struct NetworkOnly <: Player
  params :: MctsParams
end

name(::NetworkOnly) = "Network Only"

function instantiate(p::NetworkOnly, nn)
  params = MctsParams(p.params, num_iters_per_turn=0)
  return MctsPlayer(nn, params)
end

# Also implements the AlphaZero.AbstractPlayer interface
struct MinMaxTS <: Player
  depth :: Int
  ϵ :: Float64
  MinMaxTS(;depth, random_ϵ=0.) = new(depth, random_ϵ)
end

struct MinMaxPlayer{G} <: AbstractPlayer{G}
  depth :: Int
  ϵ :: Float64
end

name(p::MinMaxTS) = "MinMax (depth $(p.depth))"

function instantiate(p::MinMaxTS, nn::AbstractNetwork{G}) where G
  return MinMaxPlayer{G}(p.depth, p.ϵ)
end

import ..reset!, ..think

reset!(::MinMaxPlayer) = nothing

function think(p::MinMaxPlayer, state, turn)
  actions = GI.available_actions(state)
  aid = MinMax.minmax(state, actions, p.depth)
  n = length(actions)
  π = zeros(n); π[aid] = 1.
  η = ones(n) / n
  π = (1 - p.ϵ) * π + p.ϵ * η
  return rand(Categorical(π)), π
end

end
