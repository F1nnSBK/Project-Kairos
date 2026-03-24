module Ingest

using HTTP, JSON3, Dates, LinearAlgebra
using Model

export Article, ARTICLE_POOL, update_news!, POOL_LOCK

struct Article
	id::String
	title::String
	url::String
	timestamp::DateTime
	embedding::Vector{Float32}
end

const ARTICLE_POOL = Dict{String, Article}()
const POOL_LOCK = ReentrantLock()

const API_URL = "https://www.tagesschau.de/api2u/news/"
const HEADERS = [
	"User-Agent" => "Kairos-News-Engine/1.0",
	"Accept" => "application/json",
]
const RETENTION_PERIOD = Hour(24)
const EMBEDDING_DIM = 768

"""
	update_news!()

Fetches latest news from Tagesschau, generates embeddings, and updates the global pool.
"""
function update_news!()
	@info "Polling Tagesschau API..."

	try
		response = HTTP.get(API_URL, HEADERS)
		data = JSON3.read(response.body)
		new_count = 0

		lock(POOL_LOCK) do
			for item in get(data, :news, [])
				id = String(get(item, :sophoraId, ""))

				if isempty(id) || haskey(ARTICLE_POOL, id)
					continue
				end

				title = String(get(item, :title, ""))
				topline = String(get(item, :topline, ""))
				first_sentence = String(get(item, :firstSentence, ""))
				link = String(get(item, :details, ""))

				# Generate embedding from combined text
				input = "$topline: $title. $first_sentence"
				emb = get_mrl_embedding(input, EMBEDDING_DIM)

				ARTICLE_POOL[id] = Article(id, title, link, now(), emb)
				new_count += 1
			end

			# Prune stale articles
			cleanup_limit = now() - RETENTION_PERIOD
			filter!(p -> p.second.timestamp > cleanup_limit, ARTICLE_POOL)
		end

		@info "Ingest complete" new_articles=new_count pool_size=length(ARTICLE_POOL)
	catch e
		@error "News ingest failed" exception=(e, catch_backtrace())
	end
end

end
