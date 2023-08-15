# Feather Inventory

Feather inventory is designed to provide a realistic and immersive inventory system for players. It is based on weight, allowing players to manage their items effectively. Additionally, it features a unique player-to-player robbery system and the ability to register usable items. Moreover, the script comes with an API that enables the registration of custom inventories for various entities.

## Features

1. **Weight-based Inventory System**: Items in the inventory have weight values, ensuring players need to manage their inventory space carefully.

2. **Player-to-Player Robbery**: Players can interact with each other to initiate robberies. The script will handle the mechanics and transfer of items between the two players involved.

3. **Usable Items**: The inventory system supports registering usable items, such as consumables or items that trigger specific actions when used.

4. **Custom Inventory API**: Developers can easily register custom inventories for different entities within the game, expanding the functionality of the script to cater to specific gameplay scenarios.

## Getting Started

Follow these steps to set up the RedM inventory script in your server:

1. **Prerequisites**: Download the latest release from [Releases](https://github.com/DavFount/feather-inventory/releases)

2. **Installation**: Place the script files in your RedM server's resource folder. Ensure the feather-inventory in your [RESOURCE CONFIG FILE]

3. **Dependencies**: Feather Core - Feather core is the only dependency as of now.

4. **Configuration**: Adjust the settings in the configuration file to suit your server's gameplay style and preferences.

5. **Database Setup**: The database should be created for you automatically. If you are having issues please delete the table and restart the script.

## Usage

### Accessing Inventory

Players can access their inventory by pressing the [Inventory Key].

### Managing Items

1. **Adding Items**: Players can acquire new items through various means like looting, purchasing, receiving them as rewards, or trading with other players.

2. **Dropping Items**: Players can drop items from their inventory if they no longer need them.

3. **Using Items**: Usable items can be activated from the inventory to trigger specific actions or effects. Activate items by double clicking or dragging to use. If they are in your action slots 1-6 (6 is located at the bottom of the inventory) you can use the item by clicking those numbers.

4. **Weighing Inventory**: The inventory system will calculate and display the total weight of the items in the player's inventory.

### Player-to-Player Robbery

Players can initiate a robbery against another player by using an [Robbery Key]. The script will handle the interaction between the two players and transfer items accordingly.

### Custom Inventories

Developers can utilize the API provided by the script to register custom inventories for various entities within the game. This feature allows for expanded gameplay possibilities, such as creating unique loot systems or interactive objects.

## API Documentation

#### Accessing the API

There is a client side and server side API for inventory. To obtain access to the API follow the instructions below:

```lua
FeatherInventory = exports['feather-inventory'].initiate()
```

#### Server Side API

##### Register Foreign Key

Registers a Inventory Foreign Key for your script to utilize custom inventories.

| Parameter      | Description                                                                                 |
| -------------- | ------------------------------------------------------------------------------------------- |
| tableName      | This must be the exact name of your table where the inventory owner will be. (e.g. stables) |
| foreignKeyType | The data type used in your tables primary key. (e.g. BIGINT UNSIGNED, VARCHAR(255), INT)    |
| primaryKeyName | The name of your primary key. (e.g. id)                                                     |

###### Example Usage

```lua
FeatherInventory.RegisterForeignKey('stables', 'BIGINT UNSIGNED', 'id')
```

##### Register Inventory

Registers a custom inventory for an entity.

| Parameter | Description                                                                                 |
| --------- | ------------------------------------------------------------------------------------------- |
| tableName | This must be the exact name of your table where the inventory owner will be. (e.g. stables) |
| id        | The Owners ID from the databse (e.g. the database ID of the horse)                          |

###### Example Usage

```lua
FeatherInventory.RegisterInventory('stables', 6)
```

##### Add Item

Add an item to a given inventory.

| Parameter   | Description                                            |
| ----------- | ------------------------------------------------------ |
| itemName    | The name of the item from the database.                |
| quantity    | The quantity of the item you'd like to add.            |
| metadata    | Any metadata you'd like to add to the item. Can be nil |
| inventoryId | The UUID of the inventory you are adding the item to.  |

###### Example Usage

```lua
-- Add 6 apples to my inventory
FeatherInventory.AddItem('item_apple', 6, nil, 'c770bc77-3a77-11ee-b67f-18c04d04db03')

local metadata = { quality = 'poor', durability = 50, maxDurability = 100 }
FeatherInventory.AddItem('item_apple', 6, metadata, 'c770bc77-3a77-11ee-b67f-18c04d04db03')
```

#### Client Side API

##### Player Has Item

Checks to see if a player has a specific item or items.

| Parameter | Description                                                                                          |
| --------- | ---------------------------------------------------------------------------------------------------- |
| items     | A table of items you wish to check for. See below for an example of a properly formatted item table. |

###### Example Usage

```lua
local itemsToCheckFor = {
  {
    name = 'apple',
    quantity = 5
  },
  {
    name = 'jars',
    quantity = 2
  }
}

FeatherInventory.PlayerHasItems(itemsToCheckFor)
```

##### GetItemCount

Retrieves the amount of a specific item a player has. Returns the quantity.

| Parameter | Description                               |
| --------- | ----------------------------------------- |
| itemName  | The name of the item you are looking for. |

###### Example Usage

```lua
FeatherInventory.GetItemCount('item_train_ticket')
```

## Troubleshooting

If you encounter any issues or have questions, post in our discords bugs and support channel. You may also open an issue on the issue tracker tab of GitHub.

## Contributing

Contributions to the RedM inventory script are welcome! If you have improvements or bug fixes, feel free to submit a pull request.

## License

This inventory script is licensed under GPL3 License. Refer to the LICENSE file for more information.

## Credits

Huge inspiration from the RSG Core's inventory system.
