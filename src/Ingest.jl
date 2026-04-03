module Ingest

using HTTP, JSON3, Dates, LinearAlgebra
using Model
using Storage
using BanditCore

export Article, ARTICLE_POOL, update_news!, POOL_LOCK, CATEGORIES

struct Article
	id::String
	title::String
	url::String
	image_url::String
	timestamp::DateTime
	embedding::Vector{Float32}
end

const ARTICLE_POOL = Dict{String, Article}()
const POOL_LOCK = ReentrantLock()
const BASE_URL = "https://www.tagesschau.de"
const HEADERS = ["User-Agent" => "Kairos-Engine/2.0", "Accept" => "application/json"]
const RETENTION_PERIOD = Hour(48)
const EMBEDDING_DIM = 768

const CATEGORIES = Dict(
	"Global Markets"  => ["Wirtschaft", "Börse", "Finanzen", "DAX", "Rezession", "Zinsen"],
	"Frontier Tech"   => ["KI", "Technologie", "Innovation", "Informatik", "Halbleiter", "OpenAI"],
	"Geopolitics"     => ["Geopolitik", "Sicherheitspolitik", "NATO", "UN", "Diplomatie"],
	"Life Sciences"   => ["Biotechnologie", "Pharma", "Medizin", "Forschung", "Genetik"],
	"Space & Defense" => ["Raumfahrt", "Weltraum", "Verteidigung", "Bundeswehr", "Rüstung", "SpaceX"],
	"Sustainability"  => ["Klimawandel", "Energie", "Nachhaltigkeit", "Solar", "Wasserstoff"],
	"Digital Society" => ["Digitalisierung", "Cybersecurity", "Netzpolitik", "Datenschutz"],
	"Infrastructure"  => ["Mobilität", "Logistik", "Industrie", "Bahn", "Automobil"],
)

function update_news!()
	@async begin
		try
			new_total = 0
			for path in ["/api2u/news/", "/api2u/homepage/"]
				new_total += poll_path(path)
			end

			all_keywords = unique(reduce(vcat, values(CATEGORIES)))
			for word in all_keywords
				new_total += poll_path("/api2u/search/?searchText=$(HTTP.escapeuri(word))&pageSize=30")
				sleep(0.4)
			end

			lock(POOL_LOCK) do
				filter!(p -> p.second.timestamp > (now() - RETENTION_PERIOD), ARTICLE_POOL)
			end
			@info "Background Ingest complete" new_articles=new_total pool_size=length(ARTICLE_POOL)
		catch e
			@error "Background Ingest failed" exception=e
		end
	end
end

function poll_path(path)
	try
		res = HTTP.get(BASE_URL * path, HEADERS)
		data = JSON3.read(res.body)
		items = haskey(data, :news) ? data.news : (haskey(data, :searchResults) ? data.searchResults : [])
		return process_items!(items)
	catch
		return 0
	end
end

function process_items!(items)
	added = 0
	for item in items
		id = String(get(item, :sophoraId, get(item, :externalId, "")))

		is_new = lock(POOL_LOCK) do
			!haskey(ARTICLE_POOL, id) && !isempty(id)
		end

		if is_new
			title = String(get(item, :title, ""))
			topline = String(get(item, :topline, ""))
			first_sentence = String(get(item, :firstSentence, ""))
			link = String(get(item, :shareURL, get(item, :detailsweb, "")))

			img_url = ""
			teaser = get(item, :teaserImage, nothing)
			if teaser !== nothing
				vars = get(teaser, :imageVariants, nothing)
				if vars !== nothing
					img_url = String(get(vars, Symbol("1x1-840"), get(vars, Symbol("1x1-640"), "")))
				end
			end

			emb = Model.get_mrl_embedding("$topline: $title. $first_sentence", EMBEDDING_DIM)

			lock(POOL_LOCK) do
				ARTICLE_POOL[id] = Article(id, title, link, isempty(img_url) ? "https://via.placeholder.com/840" : img_url, now(), emb)
			end
			added += 1
		end
	end
	return added
end

function prime_user_profile!(db, user_id::String, selected_categories)
	profile = Storage.load_user(db, user_id)
	if profile === nothing
		profile = BanditCore.UserProfile(user_id, 128)
	end

	all_keywords = String[]
	for cat in selected_categories
		if haskey(CATEGORIES, string(cat))
			append!(all_keywords, CATEGORIES[string(cat)])
		end
	end

	if !isempty(all_keywords)
		cloud_text = join(all_keywords, " ")

		emb = Model.get_mrl_embedding(cloud_text, 128)

		BanditCore.update_factor!(profile, emb, 5.0f0)
	end

	Storage.save_user(db, profile)
	return profile
end

end
