module Model

using ONNXRunTime
using PythonCall
using LinearAlgebra
using Statistics

export get_mrl_embedding

const SESSION = Ref{Any}(nothing)
const TOKENIZER = Ref{Any}(nothing)
const INIT_LOCK = ReentrantLock()

const MODEL_PATH = joinpath(dirname(@__DIR__), "model", "model_fp16.onnx")

function get_session()
	lock(INIT_LOCK) do
		if SESSION[] === nothing
			@info "Searching for model..." path=MODEL_PATH
			if !isfile(MODEL_PATH)
				error("KAIROS_FATAL: Model not found at $MODEL_PATH. Check Docker COPY commands.")
			end
			SESSION[] = load_inference(MODEL_PATH)
		end
	end
	return SESSION[]
end

function get_tokenizer()
	lock(INIT_LOCK) do
		if TOKENIZER[] === nothing
			@info "Loading Tokenizer..."
			transformers = pyimport("transformers")
			model_dir = joinpath(@__DIR__, "..", "model")
			tok = transformers.AutoTokenizer.from_pretrained(model_dir)
			tok.add_special_tokens(Dict("pad_token" => "[PAD]"))
			tok.pad_token_id = 0
			TOKENIZER[] = tok
		end
	end
	return TOKENIZER[]
end

function get_mrl_embedding(text::String, dim::Int = 768)
	# Tokenizer und Session sicher abrufen
	session = get_session()
	tokenizer = get_tokenizer()

	# PythonCall ist nicht thread-safe! Wir locken auch hier zur Sicherheit.
	encoded = lock(INIT_LOCK) do
		tokenizer(text, padding = "max_length", truncation = true, max_length = 128, return_tensors = "np")
	end

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
