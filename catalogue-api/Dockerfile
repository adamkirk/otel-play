FROM golang:1.26 AS build
WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/catalogue-api . \
    && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/catalogue-api /catalogue-api
# Writable default data dir for running without a volume (e.g. plain docker run).
COPY --from=build --chown=nonroot:nonroot /out/data /data

ENV PORT=8080 DATA_PATH=/data/products.json
EXPOSE 8080
# Numeric so Kubernetes' runAsNonRoot check can verify it (65532 = nonroot).
USER 65532:65532
ENTRYPOINT ["/catalogue-api"]
