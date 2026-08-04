#!/usr/bin/env nu

def main [] {
  if (which starship | is-empty) {
    error make {msg: "starship is required before shell integration is configured"}
  }

  let autoload_dir = ($nu.data-dir | path join "vendor" "autoload")
  let starship_init = ($autoload_dir | path join "starship.nu")
  mkdir $autoload_dir
  run-external starship "init" "nu" | save --force $starship_init
  print $"reseed: Nushell Starship autoload: ($starship_init)"
}
