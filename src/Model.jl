module Model

using ONNXRunTime
using PythonCall
using LinearAlgebra
using Statistics

export get_mrl_embedding

const SESSION = Ref{Any}(nothing)
const TOKENIZER = Ref{Any}(nothing)

function get_session()
	if SESSION[] === nothing
		SESSION[] = load_inference(joinpath(@__DIR__, "..", "model", "model_fp16.onnx"))
	end
	return SESSION[]
end

function get_tokenizer()
	if TOKENIZER[] === nothing
		transformers = pyimport("transformers")
		model_dir = joinpath(@__DIR__, "..", "model")
		tok = transformers.AutoTokenizer.from_pretrained(model_dir)
		tok.add_special_tokens(Dict("pad_token" => "[PAD]"))
		tok.pad_token_id = 0
		@info "Tokenizer configured with [PAD] ID 0."
		TOKENIZER[] = tok
	end
	return TOKENIZER[]
end

function get_mrl_embedding(text::String, dim::Int = 768)
	session = get_session()
	tokenizer = get_tokenizer()

	encoded = tokenizer(text, padding = "max_length", truncation = true, max_length = 128, return_tensors = "np")
	input_ids = pyconvert(Matrix{Int64}, encoded["input_ids"])
	attention_mask = pyconvert(Matrix{Int64}, encoded["attention_mask"])
	token_type_ids = zeros(Int64, size(input_ids))

	outputs = session((
		input_ids = input_ids,
		attention_mask = attention_mask,
		token_type_ids = token_type_ids,
	))

	full_vector = vec(mean(outputs[1], dims = 2))
	sliced_vector = full_vector[1:dim]
	return sliced_vector / norm(sliced_vector)
end

end
