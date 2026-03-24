module Model

using ONNXRunTime
using WordTokenizers
using LinearAlgebra
using Statistics

export get_mrl_embedding

# Wir nutzen ein Ref, um die Session vor dem Garbage Collector zu schützen
const SESSION = Ref{Any}(nothing)

function get_session()
	if SESSION[] === nothing
		SESSION[] = load_inference("model/model_fp16.onnx")
	end
	return SESSION[]
end

function get_mrl_embedding(text::String, dim::Int = 768)
	# Dummy-Tokenisierung (bis wir WordPiece morgen mappen)
	tokens = WordTokenizers.tokenize(text)

	# Inferenz mit der stabilen Session
	session = get_session()

	# Dummy-IDs für den Start-Run
	dummy_ids = collect(1:min(length(tokens), 128))
	ids = reshape(Int64.(dummy_ids), 1, :)

	outputs = session((
		input_ids = ids,
		attention_mask = ones(Int64, size(ids)),
		token_type_ids = zeros(Int64, size(ids)),
	))

	full_vector = vec(mean(outputs[1], dims = 2))
	sliced_vector = full_vector[1:dim]
	return sliced_vector / norm(sliced_vector)
end

end
