# Checklist Application

A prototype cross-platform application written mostly in Zig for managing checklists.

## Development

Run tasks in parallel:

```bash
# run services in parallel (shell background jobs, terminal tabs, etc)
zig build --watch  # build project
zig build test --watch --summary all  # build and run unit tests
python -m http.server -d ./zig-out/web/ 8000  # serve web client content
./zig-out/bin/server  # run backend api

# create test data in backend
export CURL_POST="curl -X POST -H 'Content-Type: application/json'"
$CURL_POST --data '{"display_name": "john"}' http://localhost:8080/user
$CURL_POST --data '{"display_name": "jane"}' http://localhost:8080/user
$CURL_POST --data '{"created_by_user_id": 1, "title": "Today"}' http://localhost:8080/checklist
```

Open browser to `http://localhost:8000/` to use the application.

## Release

TODO

```bash
zig build -Doptimize=ReleaseSmall  # or ReleaseFast
```

## References

Third party libraries:

* [zigster64/zts](https://github.com/zigster64/zts)

Future improvements:

* Client integration with CookieStore API once it's baseline available:
  * https://developer.mozilla.org/en-US/docs/Web/API/CookieStore
  * https://wicg.github.io/cookie-store/
