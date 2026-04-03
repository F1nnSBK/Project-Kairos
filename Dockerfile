# --- STAGE 1: Builder ---
FROM julia:1.10.1-bookworm AS builder

RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-venv build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Project.toml ./
COPY CondaPkg.toml ./

ENV JULIA_CONDAPKG_BACKEND="Null"
ENV JULIA_PYTHONCALL_EXE="/usr/bin/python3"
ENV JULIA_DEPOT_PATH=/root/.julia

RUN julia --project=. -e 'using Pkg; Pkg.Registry.add("General"); Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()'

# --- STAGE 2: Runner ---
FROM julia:1.10.1-bookworm

RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /root/.julia /root/.julia

COPY --from=builder /app/Project.toml ./
COPY --from=builder /app/Manifest.toml ./
COPY --from=builder /app/CondaPkg.toml ./

COPY . . 

ENV JULIA_DEPOT_PATH=/root/.julia
ENV JULIA_PROJECT="@."
ENV JULIA_CONDAPKG_BACKEND="Null"
ENV JULIA_PYTHONCALL_EXE="/usr/bin/python3"

EXPOSE 8080

CMD ["julia", "--project=.", "-t", "auto", "main.jl"]