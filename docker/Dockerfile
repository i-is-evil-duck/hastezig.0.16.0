FROM alpine:3.22 AS build

WORKDIR /opt
RUN wget -q https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
 && tar -xJf zig-x86_64-linux-0.16.0.tar.xz \
 && rm zig-x86_64-linux-0.16.0.tar.xz
ENV PATH=/opt/zig-x86_64-linux-0.16.0:$PATH

WORKDIR /app
COPY . .

RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

FROM scratch
COPY --from=build /app/zig-out/bin/hastezig /hastezig
EXPOSE 960
VOLUME ["/data"]
ENTRYPOINT ["/hastezig", "0.0.0.0", "960", "/data/hastezig.db"]
