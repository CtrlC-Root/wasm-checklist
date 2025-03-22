local config = require "core.config"

config.ignore_files = {
  -- Fossil
  "^%.fslckout",

  -- Git
  "^%.git/",

  -- Skeleton
  "^/%.skeleton/",

  -- zig
  "^/%.zig%-cache/",
}
