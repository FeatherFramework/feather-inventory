fx_version "adamant"
games { "rdr3" }
rdr3_warning "I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships."
lua54 "yes"

description 'The Inventory API for the Feather Framework'
author 'BCC Scripts'
name 'feather-inventory'
version '0.1.0'

github_version_check 'false'
github_version_type 'release'
github_ui_check 'false'
github_link 'https://github.com/FeatherFramework/feather-inventory'

shared_scripts {
  "config.lua",
  "shared/*.lua",
}

server_scripts {
  "@oxmysql/lib/MySQL.lua",
  "/server/coreapi.lua",
  "/server/helpers/*.lua",
  "/server/controllers/*.lua",
  "/server/services/*.lua",
  "/server/main.lua",
}

client_scripts {
  "/client/helpers/*.lua",
  "/client/services/*.lua",
  "/client/controllers/*.lua",
  "/client/main.lua",
}

ui_page {
  "ui/shim.html"
}

files {
  "ui/shim.html",
  "ui/js/*.*",
  "ui/css/*.*"
}

dependencies {
  'oxmysql',
}
