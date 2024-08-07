fx_version "cerulean"
games { "rdr3" }
rdr3_warning "I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships."
lua54 "yes"

description 'The Inventory API for the Feather Framework'
author 'BCC Scripts'
name 'feather-inventory'
version '0.1.2'

github_version_check 'true'
github_version_type 'release'
github_ui_check 'true'
github_link 'https://github.com/FeatherFramework/feather-inventory'

shared_scripts {
  "config.lua"
}

server_scripts {
  "@oxmysql/lib/MySQL.lua",
  "/server/imports.lua",
  "/server/helpers/*.lua",
  "/server/controllers/*.lua",
  "/server/services/*.lua",
  "/server/main.lua",
}

client_scripts {
  "/client/imports.lua",
  "/client/helpers/*.lua",
  "/client/controllers/*.lua",
  "/client/services/*.lua",
  "/client/main.lua",
}

ui_page {
   "ui/index.html"
}

files {
  "ui/index.html",
  "ui/js/*.*",
  "ui/css/*.*",
  "ui/fonts/*.*",
  "ui/images/*.*",
  "ui/img/*.*"
}

dependencies {
  'oxmysql',
}
