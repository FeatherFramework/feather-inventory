# Feather Inventory

Feather inventory is designed to provide a realistic and immersive inventory system for players. It is based on weight, allowing players to manage their items effectively. Additionally, it features a unique player-to-player robbery system and the ability to register usable items. Moreover, the script comes with an API that enables the registration of custom inventories for various entities.

## Features

1. **Player inventory**: Provides players with an inventory
2. **Secondary/Custom inventory**: Developers can utilize the API provided by the script to register custom inventories for various entities within the game. This feature allows for expanded gameplay possibilities, such as creating unique loot systems or interactive objects.
3. **Ground inventory**: A global ground inventory for when players drop items
4. **Usable Items**: The inventory system supports registering usable items, such as consumables or items that trigger specific actions when used.
5. **Custom Inventory API**: Developers can easily register custom inventories for different entities within the game, expanding the functionality of the script to cater to specific gameplay scenarios.

## Getting Started

Follow these steps to set up the RedM inventory script in your server:

1. **Prerequisites**: Download the latest release from [Releases](https://github.com/DavFount/feather-inventory/releases)
2. **Installation**: Place the script files in your RedM server's resource folder. Ensure the feather-inventory in your [RESOURCE CONFIG FILE]
3. **Dependencies**: Feather Core - Feather core is the only dependency as of now.
4. **Configuration**: Adjust the settings in the configuration file to suit your server's gameplay style and preferences.
5. **Database Setup**: The database should be created for you automatically. If you are having issues please delete the table and restart the script.


## API Documentation

#### Accessing the API

There is a client side and server side API for inventory. To obtain access to the API follow the instructions below:

```lua
FeatherInventory = exports['feather-inventory'].initiate()
```

#### Server Side Inventory API
Link TBD

## Troubleshooting

If you encounter any issues or have questions, post in our discords bugs and support channel. You may also open an issue on the issue tracker tab of GitHub.

## Contributing

Contributions to the RedM inventory script are welcome! If you have improvements or bug fixes, feel free to submit a pull request.

## License

This inventory script is licensed under GPL3 License. Refer to the LICENSE file for more information.

## Credits

Huge inspiration to RDO's inventory system with many QOL improvements.

## To-Do

- Add LOD to load ground items within a view distance
- Make character initiate loadscreen text configurable.
- Migrate all language/text to locales
- Make secondary inventory titles customizable
- Frontend UI
  - Add Inventory specific slot counts
  - Account for inventory specific ignore limits (ignore item caps)

### Next version improvements

- Frontend UI
    - Migrate frontend to use state management.
    - Shift + Drag will transfer or drop all items (no modal displays in this case.)