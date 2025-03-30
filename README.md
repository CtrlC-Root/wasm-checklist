# Checklist Application

A demo cross-platform application written mostly in Zig for managing checklists.

## Development

Run tasks in parallel:

```bash
zig build --watch  # build project
zig build test --watch --summary all  # build and run unit tests
python -m http.server -d ./zig-out/web/ 8000  # serve web client content
./zig-out/bin/server  # service backend api
```

Open browser to `http://localhost:8000/` to use the application.

## Release

TODO

```bash
zig build -Doptimize=ReleaseSmall  # or ReleaseFast
```
