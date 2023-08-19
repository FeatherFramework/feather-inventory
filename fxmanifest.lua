fx_version "adamant"
games { "rdr3" }
rdr3_warning "I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships."
lua54 "yes"

description 'The Inventory API for the Feather Framework'
author 'BCC Scripts'
name 'feather-inventory'
version '0.0.1'
github ''
github_type ''

shared_scripts {
  "shared/*.lua",
  "/config.lua",
}

server_scripts {
  "@oxmysql/lib/MySQL.lua",
  "/server/helpers/*.lua",
  "/server/controllers/*.lua",
  "/server/services/*.lua",
  "/server/main.lua",
}

client_scripts {
  "/client/helpers/*.lua",
  "/client/services/*.lua",
  "/client/main.lua",
}

dependencies {
  'oxmysql',
}
