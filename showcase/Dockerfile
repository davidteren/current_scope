# syntax=docker/dockerfile:1
# check=error=true

# Production image for the CurrentScope *showcase* host app.
#
# IMPORTANT: build from the REPO ROOT, not from showcase/. The showcase depends
# on the engine via a path gem (`gem "current_scope", path: ".."`) that lives
# ABOVE showcase/, so a showcase-scoped build context can't `bundle install`.
# Kamal is configured (showcase/config/deploy.yml) with `builder.context: ..`
# and this Dockerfile, which lays the app out as:
#
#   /rails            <- engine (gem) root: app/ config/ db/ lib/ + gemspec
#   /rails/showcase   <- the Rails app (Rails.root); `path: ".."` resolves here
#
# Keeping the gem at /rails (not the container root /) avoids colliding its
# lib/ with the system /lib.
#
# Build/run by hand from the repo root:
#   docker build -f showcase/Dockerfile -t showcase .
#   docker run -d -p 80:80 -e RAILS_MASTER_KEY=<showcase/config/master.key> --name showcase showcase

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.9
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# The Rails app lives one directory below the engine (gem) root so the path gem
# `..` resolves to /rails.
WORKDIR /rails/showcase

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Engine (path gem) source, copied to the gem root /rails so the showcase's
# `gem "current_scope", path: ".."` resolves at bundle-install time. Its lib/
# lands at /rails/lib, clear of the container's system /lib.
COPY app        /rails/app
COPY config     /rails/config
COPY db         /rails/db
COPY lib        /rails/lib
COPY current_scope.gemspec Rakefile MIT-LICENSE README.md /rails/

# Install showcase gems (the path gem above must already be present).
COPY showcase/Gemfile showcase/Gemfile.lock ./
COPY showcase/vendor ./vendor
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy showcase application code
COPY showcase/ .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, engine + application (the whole /rails tree)
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/showcase/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
