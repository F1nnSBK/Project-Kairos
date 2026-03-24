module BanditCore

using LinearAlgebra
using Dates

export UserProfile, scfd_update!

"""
	UserProfile

State for the SCFD algorithm.
- `L`: Cholesky factor where \$A = L L^\\top\$.
- `γ`: Drift factor \$\\gamma \\in (0, 1]\$.
"""
mutable struct UserProfile
	user_id::String
	dim::Int
	L::Matrix{Float32}
	b::Vector{Float32}
	γ::Float32
end

function UserProfile(user_id::String, dim::Int; γ = 0.99f0)
	L = Matrix{Float32}(I, dim, dim)
	b = zeros(Float32, dim)
	return UserProfile(user_id, dim, L, b, γ)
end

"""
	scfd_update!(profile, x, reward)

Updates the profile using the SCFD algorithm:
1. Apply drift: \$L \\leftarrow \\sqrt{\\gamma} L\$ and \$b \\leftarrow \\gamma b\$.
2. Rank-1 update: If \$r > 0.05\$, update \$L\$ via `lowrankupdate!` with \$\\sqrt{r}x\$ and \$b \\leftarrow b + rx\$.
"""
function scfd_update!(profile::UserProfile, x::Vector{Float32}, reward::Float32)
	profile.L .*= sqrt(profile.γ)
	profile.b .*= profile.γ

	if reward > 0.05f0
		update_vec = sqrt(reward) .* x
		lowrankupdate!(profile.L, update_vec)
		profile.b .+= reward .* x
	end
end

end
