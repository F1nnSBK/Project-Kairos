# --- STAGE 1: Builder ---
FROM julia:1.10.1-bookworm AS builder

RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-venv build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu --break-system-packages && \
    pip3 install --no-cache-dir transformers --break-system-packages

WORKDIR /app

COPY Project.toml CondaPkg.toml ./

ENV JULIA_DEPOT_PATH=/root/.julia
ENV JULIA_CONDAPKG_BACKEND="Null"
ENV JULIA_PYTHONCALL_EXE="/usr/bin/python3"

RUN julia --project=. -e 'using Pkg; Pkg.Registry.add("General"); Pkg.instantiate(); using ONNXRunTime; println("--- ARTIFACTS PRE-LOADED ---")'

# --- STAGE 2: Runner ---
FROM julia:1.10.1-bookworm

RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu --break-system-packages && \
    pip3 install --no-cache-dir transformers --break-system-packages

WORKDIR /app

COPY --from=builder /root/.julia /root/.julia

COPY --from=builder /app/Project.toml ./
COPY --from=builder /app/CondaPkg.toml ./
COPY --from=builder /app/Manifest.toml ./

COPY . .

ENV JULIA_DEPOT_PATH=/root/.julia
ENV JULIA_PROJECT="@."
ENV JULIA_CONDAPKG_BACKEND="Null"
ENV JULIA_PYTHONCALL_EXE="/usr/bin/python3"

EXPOSE 8080

CMD ["julia", "--project=.", "main.jl"]