module BanditCore

using LinearAlgebra
using Dates

export UserProfile, update_factor!, robust_reward, get_recommendations

mutable struct UserProfile
	user_id::String
	dim::Int
	L::Matrix{Float32} # Cholesky factor of covariance matrix A (A = L*L')
	b::Vector{Float32} # accumulated feature vector weighted by reward
	γ::Float32         # forgetting factor (0.99 = slow forgetting)
	last_interaction::DateTime
end

function UserProfile(user_id::String, dim::Int; γ = 0.99f0)
	L = Matrix{Float32}(0.3f0 * I, dim, dim)
	b = zeros(Float32, dim)
	return UserProfile(user_id, dim, L, b, γ, now())
end

"""
Compute a time-based reward to discourage bot spam.
"""
function robust_reward(last_time::DateTime, current_time::DateTime; τ = 3.0)
	dt = (current_time - last_time).value / 1000.0
	dt < 0.5 && return 0.0f0
	return min(1.0f0, Float32(dt / τ))
end

"""
Update user profile with click/dismiss signals.
"""
function update_factor!(profile::UserProfile, x::Vector{Float32}, reward::Float32)
	profile.L .*= sqrt(profile.γ)
	profile.b .*= profile.γ

	x_norm = x ./ (norm(x) + 1.0f-6)

	if reward > 0.05f0
		update_vec = sqrt(reward * 1.5f0) .* x_norm
		C = Cholesky(profile.L, 'L', 0)
		lowrankupdate!(C, update_vec)
		profile.b .+= reward .* x_norm

	elseif reward < -0.05f0
		profile.b .+= reward .* x_norm
	end

	profile.last_interaction = now()
end

"""
Compute recommendations using LinUCB: score = μ + α * σ.
"""
function get_recommendations(profile::UserProfile, articles, α::Float32)
	L_tri = LowerTriangular(profile.L)
	y = L_tri \ profile.b
	θ = L_tri' \ y

	scored = map(articles) do art
		x = @view art.embedding[1:profile.dim]
		μ = dot(θ, x)
		z = L_tri \ x
		σ = norm(z)
		return (article = art, score = μ + α * σ)
	end

	sort!(scored, by = x -> x.score, rev = true)
	return [item.article for item in scored]
end

end
