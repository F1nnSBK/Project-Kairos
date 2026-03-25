module BanditCore

using LinearAlgebra
using Dates

export UserProfile, update_factor!, robust_reward, get_recommendations

mutable struct UserProfile
	user_id::String
	dim::Int
	L::Matrix{Float32}
	b::Vector{Float32}
	γ::Float32
	last_interaction::DateTime
end

function UserProfile(user_id::String, dim::Int; γ = 0.99f0)
	L = Matrix{Float32}(0.1f0 * I, dim, dim)
	b = zeros(Float32, dim)
	return UserProfile(user_id, dim, L, b, γ, now())
end

function robust_reward(last_time::DateTime, current_time::DateTime; τ = 3.0)
	dt = (current_time - last_time).value / 1000.0
	dt < 0.5 && return 0.0f0
	return min(1.0f0, Float32(dt / τ))
end

function update_factor!(profile::UserProfile, x::Vector{Float32}, reward::Float32)
	profile.L .*= sqrt(profile.γ)
	profile.b .*= profile.γ

	if reward > 0.05f0
		x_norm = x ./ (norm(x) + 1.0f-6)
		update_vec = sqrt(reward * 2.0f0) .* x_norm

		C = Cholesky(profile.L, 'L', 0)
		lowrankupdate!(C, update_vec)
		profile.b .+= reward .* x
	end

	profile.last_interaction = now()
end

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
