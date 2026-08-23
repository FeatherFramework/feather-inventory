# Feather Weapons — Dependency Audit and Support Plans

> Requirements baseline: [`MASTER_PLAN.md`](./MASTER_PLAN.md)  
> Audit scope: supporting Feather resources in this workspace  
> Excluded as a design input: the abandoned `feather-weapons` implementation  
> Compatibility policy: the weapons system is greenfield; dependent-resource changes should preserve their unrelated consumers where practical

## 1. Purpose

This document audits the current Feather resources that must support the weapons master plan and defines a delivery plan for each one. It does not derive requirements from the old weapons code. The target contracts come exclusively from the weapons master plan: database item ownership, server-authoritative mutation, atomic inventory operations, stable character lifecycle events, secure RPC, auditable administration, cancellable interactions, and documented installation.

The main architectural boundary is:

```text
feather-core                  identity, RPC, lifecycle, notifications
     |
feather-character             character selection/spawn presentation
     |
feather-inventory             item identity, ownership, containers, atomic mutations
     |
feather-weapons               weapon domain and game-native representation
     |                 |                   |
feather-admin       feather-menu      feather-progressbar
operations UI       interaction UI    cancellable actions
     |
feather-recipe + feather-website      installation, schema, documentation
```

## 2. Executive assessment

| Resource | Relationship | Current readiness | Primary gap | Blocks first vertical slice? |
|---|---|---:|---|---:|
| `feather-inventory` | Hard runtime dependency | Low | No first-class unique-item, transaction, compare-and-set metadata, or mutation-hook contract | Yes |
| `feather-core` | Hard runtime dependency | Medium | Lifecycle/RPC primitives exist but need formal versioned contracts and resource-facing policy helpers | Yes |
| `feather-character` | Lifecycle producer/presentation | Medium | Spawn is available; switch/logout/death/respawn semantics are not a complete documented state machine | Yes |
| `feather-admin` | Privileged operations and audit UI | Medium | Strong internal permissions/audit exist, but no cross-resource weapon administration contract | No for core; yes for admin release |
| `feather-progressbar` | Interaction presentation | Low | Start/cancel exists, but no robust completion/cancellation result contract or interruption policy | No |
| `feather-menu` | Interaction presentation | Medium | Menu/page API exists, but lacks a standardized server-backed action model and lifecycle cleanup contract | No |
| `feather-recipe` | Fresh-install schema and ordering | Low | Current schema has generic item metadata and a legacy character-ammo table; no new weapon support migrations | Yes for release/install |
| `feather-website` | Public integration documentation | Low | Documents current inventory calls but not the new atomic/unique-item/lifecycle contracts | No for development; yes for release |

### 2.1 Critical path

```text
Core contract freeze
        |
Character lifecycle freeze
        |
Inventory unique-item + transaction foundation
        |
Weapons vertical slice
        |
Admin / UI adapters
        |
Recipe, docs, release validation
```

### 2.2 Cross-resource decisions that must be made first

1. Define a shared result envelope and error-code convention.
2. Define authoritative character session identity and lifecycle event payloads.
3. Define inventory item-instance identity and unique-item semantics.
4. Define transaction, locking, idempotency, and post-commit notification behavior.
5. Decide whether inventory metadata remains key/value rows or gains a JSON document/version column.
6. Decide which resource owns generic audit storage versus weapon-domain audit records.
7. Define resource startup readiness and dependency-health behavior.

## 3. Shared contract standards

Every dependency plan below should implement these standards consistently.

### 3.1 Result envelope

```lua
{ ok = true, value = result, correlationId = correlationId }
{ ok = false, error = { code = 'STABLE_CODE', message = '...', details = {} }, correlationId = correlationId }
```

- Machine-readable codes are stable; localized messages are presentation concerns.
- Invalid input, denied policy, conflict, unavailable dependency, and internal failure are distinct.
- Public functions do not mix `false`, `nil`, strings, and `{ error = true }` for equivalent failures.

### 3.2 Mutation context

All cross-resource mutations accept a server-created context:

```lua
{
  actorSource = source,
  actorCharacterId = characterId,
  reason = 'reload',
  correlationId = '...',
  idempotencyKey = '...',
  resource = 'feather-weapons'
}
```

The called service re-derives identity where a player source is available. Context improves auditability; it never grants authority.

### 3.3 Notifications

- Domain notifications fire only after commit.
- Event payloads contain stable IDs and immutable summaries, not live mutable objects.
- Internal server events are not network registered.
- Pre-commit hooks can veto only through a documented synchronous contract.
- Post-commit consumers cannot roll back committed state.

### 3.4 Readiness

Each hard dependency exposes a readiness/version query. `feather-weapons` must fail clearly at startup if a required contract is missing rather than partially starting.

---

## 4. `feather-inventory` support plan

### 4.1 Role in the weapons architecture

`feather-inventory` owns item definitions, item-instance identity, inventory/container ownership, capacity, movement, and persistence. It must remain the sole source of truth for who owns or can access a weapon item. It must not implement weapon-specific rules such as caliber compatibility, degradation, serial policy, or firing behavior.

### 4.2 Verified current state

- Item definitions live in `items`; owned units live in `inventory_items` with numeric primary keys.
- Metadata is stored as key/value rows in `item_metadata` with `VARCHAR(50)` keys and `VARCHAR(100)` values.
- `ItemsAPI` currently provides add, remove by name/ID, set metadata, get item/count, existence checks, inventory checks, usable-item registration, use, and ground drop.
- `InventoryAPI` provides inventory registration, capacity checks, reads, access controls, persistent grants, temporary grants, and movement-related operations.
- Item movement emits internal `feather-inventory:ItemRemoved` and `ItemAdded` events after row updates.
- Character inventories are created from the authoritative internal core spawn event.
- Existing calls use inconsistent result shapes and perform multiple independent database statements.
- A stack may be represented by multiple `inventory_items` rows; unique-instance semantics are not explicit at the item-definition level.
- Metadata values are too small for a safe versioned weapon document and are updated one key at a time.
- Inventory capacity notes indicate weight enforcement is not complete.
- Movement logic has centralized ownership checks, but there is no general transaction/lease API for a multi-item weapon operation.

### 4.3 Gap assessment

The master plan cannot safely implement weapon creation, reload, unload, attachment installation, purchase, repair, transfer, or confiscation through the current API without race windows or compensating code duplicated in `feather-weapons`.

The inventory must add generic primitives, not weapon-specific shortcuts.

### 4.4 Required target contracts

#### Item definitions

- Add explicit `stackable` or `instance_mode` (`stack` / `unique`) behavior.
- Enforce quantity `1` per unique item row.
- Expose full item definition reads including type, usability, category, limits, and instance mode.
- Allow definition tags or attributes without teaching inventory what a weapon is.

#### Item instances

- Return a normalized item instance containing item ID, definition, inventory/container ID, slot, quantity semantics, metadata document, and metadata revision.
- Provide reads by instance ID with optional ownership/access assertions.
- Provide queries by definition/type/tag without leaking unauthorized inventories.
- Preserve instance identity during movement.

#### Metadata

- Support an atomic versioned metadata document large enough for weapon state.
- Prefer a JSON column on `inventory_items` or a dedicated document table; retain key/value metadata only as a compatibility projection if needed.
- Add optimistic concurrency through `expectedRevision` or row locking.
- Validate maximum document size and JSON shape at the inventory boundary.
- Return the new revision after a successful write.

#### Transactions and locks

Add a server-only transaction API capable of:

- locking one or more item instances in deterministic order
- reading current state inside the transaction
- adding/removing quantity items
- creating/deleting unique instances
- moving instances between inventories
- updating metadata with revision checks
- enforcing capacity/slot/weight rules
- committing once and emitting notifications afterward
- rolling back every change on failure

Candidate interface:

```lua
Inventory.Transaction(context, function(tx)
  local weapon = tx:GetItemForUpdate(weaponItemId)
  tx:RemoveByDefinition(ammoInventoryId, ammoDefinitionId, rounds)
  tx:SetMetadata(weaponItemId, nextMetadata, weapon.metadataRevision)
  return { weaponItemId = weaponItemId, loaded = rounds }
end)
```

#### Idempotency and mutation guards

- Accept an idempotency key for retryable multi-step actions.
- Provide item-instance leases or transaction locks that reject conflicting equip/reload/transfer operations.
- Add a generic pre-move guard registration so `feather-weapons` can require authoritative unequip before an equipped item moves.
- Ensure guard timeouts fail closed and do not leave permanent locks.

#### Events

Replace ambiguous item removed/added signals with structured post-commit notifications:

```lua
Feather:Inventory:ItemCreated
Feather:Inventory:ItemMoved
Feather:Inventory:ItemMetadataChanged
Feather:Inventory:ItemDestroyed
Feather:Inventory:TransactionCommitted
```

Payloads include instance ID, old/new inventory IDs where applicable, definition ID/name, correlation ID, and safe reason. Existing events may remain for unrelated consumers but are insufficient for weapons.

#### Container access

- Expose a server-only `CanAccessInventory(source, inventoryId, action, context)` decision.
- Distinguish read, insert, remove, manage, and temporary-world-pickup access.
- Revalidate temporary access at mutation time.
- Support evidence/job storage through generic ACL adapters rather than hardcoded weapon rules.

### 4.5 Delivery phases

#### INV-W1 — Contract and schema foundation

- Finalize unique-item and metadata-document design.
- Add schema migrations and normalized read models.
- Introduce shared result/error contracts.
- Add feature/version readiness export.

**Exit gate:** a unique item with versioned metadata can be created, read, and updated without losing its identity.

#### INV-W2 — Transactions and concurrency

- Implement transaction wrapper and deterministic row locking.
- Add revision compare-and-set.
- Add idempotency records or bounded idempotency cache.
- Make capacity, slot, quantity, metadata, and movement changes commit atomically.

**Exit gate:** simultaneous updates to one item yield one commit and one explicit conflict; no partial state remains.

#### INV-W3 — Movement guards and events

- Add pre-move/destroy guard registry.
- Add structured post-commit events.
- Cover give, ground drop/pickup, container move, admin removal, and deletion through the same mutation pipeline.

**Exit gate:** every item movement can be observed after commit and an equipped weapon can be synchronously blocked/unequipped before movement.

#### INV-W4 — Capacity and hardening

- Complete weight/capacity enforcement.
- Add metadata size limits, access-mode checks, failure diagnostics, and transaction metrics.
- Add concurrency, rollback, replay, and restart tests.

**Exit gate:** the weapon vertical-slice transaction suite passes against the real inventory implementation.

### 4.6 Acceptance checklist

- [ ] Unique item instance cannot stack or split.
- [ ] Metadata document and revision update atomically.
- [ ] Reload can remove ammo items and update weapon metadata in one commit.
- [ ] Attachment install can consume/move one item and update another in one commit.
- [ ] Purchase can create a unique weapon only if payment coordination succeeds.
- [ ] Transfer preserves weapon instance ID and metadata.
- [ ] Concurrent requests cannot duplicate ammo, attachments, or weapon instances.
- [ ] Post-commit events fire exactly once per committed operation.
- [ ] All mutation paths enforce live container access.
- [ ] Restart leaves no in-memory lock as persistent authority.

---

## 5. `feather-core` support plan

### 5.1 Role in the weapons architecture

`feather-core` owns authenticated player/character resolution, server/client RPC transport, foundational lifecycle signals, notifications/localization access, and shared operational conventions. It must provide trustworthy infrastructure without owning weapon or inventory state.

### 5.2 Verified current state

- `Feather.Character.GetCharacter({ src = source })` provides server-side character resolution.
- Core emits internal `Feather:Server:Character:Spawned` after ownership has been verified.
- Core emits `Feather:Character:Logout` during character teardown.
- The shared RPC layer supports registered calls and has rate-limit options used by newer resources.
- Notification and locale services already exist.
- Event naming contains both client-facing and internal server-facing variants, and lifecycle payloads are not yet presented as one documented versioned state machine.

### 5.3 Gap assessment

The weapons design requires more than a spawn signal. It needs unambiguous session identity, switch/logout ordering, death/incapacitation/respawn signals, resource recovery behavior, cancellation of in-flight RPC work, and consistent rate-limit/error behavior.

### 5.4 Required target contracts

#### Character session identity

- Expose a server-generated character session token/generation that changes on character switch or logout.
- Resolve `{ source, characterId, sessionId }` together on the server.
- Allow services to assert that a session is still current before commit.
- Never accept client-supplied character identity as authority.

#### Lifecycle state machine

Define and document internal server events with stable payloads:

```text
CharacterLoading
CharacterReady
CharacterLeaving
CharacterLeft
CharacterDied / Incapacitated
CharacterRevived / Respawned
```

Each event must define ordering, whether the character object remains available, session ID behavior, and whether database state may still be mutated.

`CharacterReady` should replace ambiguous interpretations of “spawned” for server dependencies. Existing events may be bridged for other consumers.

#### RPC contract

- Standardize result envelopes and transport-level errors.
- Make payload limits, per-route rate limits, timeouts, and cancellation explicit.
- Expose correlation IDs to handlers and responses.
- Provide a route registration option that requires a current character session.
- Reject late responses after logout/switch.
- Ensure internal server calls do not traverse client-reachable event names.

#### Resource readiness and diagnostics

- Expose core API version/capabilities.
- Provide structured logging helpers with correlation IDs and redaction.
- Provide dependency-ready/resource-stopping signals or documented FiveM lifecycle integration.

### 5.5 Delivery phases

#### CORE-W1 — Lifecycle contract

- Document current event ordering.
- Introduce session IDs and authoritative ready/leaving/left events.
- Add switch/logout/reconnect tests.

**Exit gate:** a service can prove that the same character session is still active at both request and commit time.

#### CORE-W2 — RPC hardening

- Add character-required routes, correlation IDs, standardized errors, cancellation, and late-response suppression.
- Publish route security defaults.

**Exit gate:** weapon requests cannot commit for a logged-out or replaced character session.

#### CORE-W3 — Operational contract

- Add capability/version query and structured log context.
- Document notification/localization boundaries.
- Add lifecycle and RPC metrics.

**Exit gate:** hard dependencies can fail startup with a precise missing-capability message.

### 5.6 Acceptance checklist

- [ ] Server can derive current character and session from source.
- [ ] Character switch invalidates the previous session before the next becomes ready.
- [ ] Logout ordering allows weapons to persist/unequip safely.
- [ ] Death and respawn semantics are documented and tested.
- [ ] RPC routes can require a live character session.
- [ ] Correlation IDs flow from request through inventory transaction and audit.
- [ ] Rate-limit, payload, timeout, and cancellation behavior is consistent.

---

## 6. `feather-character` support plan

### 6.1 Role in the weapons architecture

`feather-character` owns character selection, creation, spawning, and client-side character presentation. It should consume and drive core lifecycle transitions but must not manage weapon persistence, native loadouts, ammunition, or inventory items.

### 6.2 Verified current state

- The resource implements character selection, creation, spawn, and appearance flows.
- Client consumers use `Feather:Character:Spawned` as the main ready signal.
- Authoritative server character state is primarily provided by `feather-core`.
- No complete weapons-ready death/respawn/switch contract is documented in this resource.

### 6.3 Required target contracts

- Make spawn completion explicit: ped exists, appearance is applied, controls are ready, and the current core session matches.
- Signal selection/switch start so weapon presentation can be removed before the old ped/session disappears.
- Signal client teardown and ready states without asking clients to rebroadcast authoritative character IDs.
- Integrate authoritative death, incapacitation, revive, and respawn transitions with core.
- Define ped replacement/model-change behavior so equipped native weapons and holster props are always cleaned and rehydrated.
- Ensure repeated ready events are idempotent and carry a session generation.

### 6.4 Delivery phases

#### CHAR-W1 — Lifecycle mapping

- Map selection, creation, spawn, switch, model replacement, death, revive, and logout flows.
- Align each transition with the new core lifecycle state machine.

**Exit gate:** every route through character selection produces the same ordered lifecycle sequence.

#### CHAR-W2 — Client presentation hooks

- Add pre-despawn/teardown and post-ped-ready client events.
- Include session generation and no client-authoritative ownership fields.
- Add resource-restart rehydration query.

**Exit gate:** weapon/holster presentation can cleanly tear down and rebuild without duplicates.

#### CHAR-W3 — Scenario tests

- Test normal login, first spawn, character switch, reconnect, death, revive, respawn, model change, and resource restart.

**Exit gate:** lifecycle consumers receive no missing, duplicated, or out-of-order terminal transitions.

### 6.5 Acceptance checklist

- [ ] Character switch announces teardown before old-session invalidation completes.
- [ ] Client-ready fires only after the usable player ped exists.
- [ ] Death/incapacitation and revive/respawn are distinguishable.
- [ ] Ped replacement causes native weapon and prop cleanup.
- [ ] No client event can claim a different authoritative character ID.
- [ ] Restart rehydration does not simulate ownership; it requests server state.

---

## 7. `feather-admin` support plan

### 7.1 Role in the weapons architecture

`feather-admin` provides permission-gated operator workflows and searchable administration history. It must call the public `feather-weapons` domain API and must never edit item metadata or weapon tables directly.

### 7.2 Verified current state

- The resource has centralized role-level permission checks through `FeatherAdmin.CanUse` / `RequirePermission`.
- RPC registration supports route-specific limits.
- Inventory administration can grant generic items.
- `feather_admin_actions` and the audit UI provide structured action history with sensitive-field filtering.
- The admin inventory flow currently calls generic inventory APIs and knows nothing about weapon-domain validation or provenance.

### 7.3 Required target contracts

#### Permissions

Add distinct permissions rather than one broad weapon-admin switch:

- `weapons.view`
- `weapons.serial.search`
- `weapons.grant`
- `weapons.repair`
- `weapons.disable`
- `weapons.confiscate`
- `weapons.return`
- `weapons.destroy`
- `weapons.reconcile`
- `weapons.audit.sensitive`

#### Operations

- Inspect weapon item instances and safe metadata.
- Search by item-instance ID or serial.
- Grant through `CreateWeaponItem` with admin provenance.
- Repair/disable/confiscate/return/destroy through domain exports.
- Trigger reconciliation for an online character.
- Require a reason and confirmation for destructive or evidentiary actions.
- Display stable error codes as localized operator messages.

#### Audit integration

- Either accept weapon audit notifications into the existing admin action store or federate read-only weapon audit results into the admin UI.
- Preserve the weapon audit record as the domain authority; admin display is not the only copy.
- Link actor, target, item instance, serial, correlation ID, action, outcome, reason, and safe before/after summary.
- Apply separate permission checks to sensitive identifiers and metadata.

### 7.4 Delivery phases

#### ADMIN-W1 — Contract adapter

- Add optional `feather-weapons` capability detection.
- Implement server-only adapter functions using public weapons exports.
- Add permission entries and localized errors.

**Exit gate:** admin cannot perform any weapon mutation by writing inventory metadata directly.

#### ADMIN-W2 — Inspection and action UI

- Add weapon list/details, serial search, grant, repair, disable, confiscate, return, destroy, and reconcile flows.
- Add confirmation/reason forms and pagination.

**Exit gate:** each action is independently permission gated and returns the committed domain result.

#### ADMIN-W3 — Audit federation

- Add weapon filters and item/serial/correlation links.
- Apply sensitive-field redaction.
- Add failure and blocked-action visibility.

**Exit gate:** an operator can trace a weapon from creation through every privileged lifecycle action.

### 7.5 Acceptance checklist

- [ ] Generic item grant cannot bypass weapon metadata creation rules.
- [ ] Every weapon admin action requires the narrow permission.
- [ ] Destructive actions require explicit reason and confirmation.
- [ ] Offline/online targets behave predictably through stable IDs.
- [ ] Audit results include failures and denied attempts where policy requires.
- [ ] Sensitive metadata is permission filtered.

---

## 8. `feather-progressbar` support plan

### 8.1 Role in the weapons architecture

The progress bar presents timed interactions such as reload, unload, cleaning, repair, attachment work, crafting, and confiscation. It does not decide whether an action is allowed or committed.

### 8.2 Verified current state

- The client export exposes a start function and cancellation hook.
- A separate export cancels the current progress bar.
- The implementation is presentation-oriented and does not expose a clearly standardized result object for completion, cancellation reason, interruption, or replacement.

### 8.3 Required target contracts

- Return exactly one terminal result: completed, cancelled, interrupted, replaced, or failed.
- Provide a unique operation ID and ignore stale NUI callbacks.
- Support cancellation by movement, damage, death, weapon change, control input, resource stop, and explicit caller request.
- Allow callers to supply allowed controls/animation/prop cleanup hooks without granting commit authority.
- Guarantee focus, animation, prop, and queue cleanup on all terminal paths.
- Expose whether a progress action is active without leaking caller internals.
- Make queued-versus-replace behavior explicit.

### 8.4 Delivery phases

#### PROGRESS-W1 — Terminal result contract

- Introduce operation IDs and a one-shot result callback/promise.
- Define cancellation reasons and replacement policy.

**Exit gate:** every started operation resolves exactly once.

#### PROGRESS-W2 — Interruption and cleanup

- Add configurable interruption monitors.
- Centralize animation, prop, input, focus, and resource-stop cleanup.

**Exit gate:** no cancel/death/restart path leaves stuck UI, focus, animation, or props.

#### PROGRESS-W3 — Weapons integration tests

- Test reload, repair, attachment, confiscation, interruption, and server rejection after visual completion.

**Exit gate:** progress completion only triggers a server revalidation request and never commits state locally.

### 8.5 Acceptance checklist

- [ ] Exactly one terminal result per operation.
- [ ] Cancellation reason is machine readable.
- [ ] Death, ped replacement, and resource stop clean up immediately.
- [ ] Stale NUI callbacks cannot complete a newer operation.
- [ ] Server rejection after completion is handled cleanly.

---

## 9. `feather-menu` support plan

### 9.1 Role in the weapons architecture

`feather-menu` can provide inspect, maintenance, customization, unload, transfer, and confirmation interfaces where a full dedicated weapons NUI is unnecessary. It remains a presentation toolkit.

### 9.2 Verified current state

- The client API supports menu registration, pages, elements, routing, updates, notifications, and open/close callbacks.
- NUI callbacks dispatch directly to registered client element callbacks.
- Menu state is client-local and does not provide a standardized server-backed action lifecycle.

### 9.3 Required target contracts

- Add a reusable async action state: idle, pending, succeeded, failed, cancelled.
- Disable or debounce elements while a server request is pending.
- Support stable row/entity keys so refreshed weapon lists do not act on stale indexes.
- Provide confirmation and reason-input components suitable for transfer, unload, and destructive actions.
- Add loading, empty, permission-denied, dependency-unavailable, and retry states.
- Guarantee close/resource-stop cleanup and late-response suppression.
- Provide accessible labels and non-color-only status indicators.

These should be generic menu capabilities; weapon-specific screens remain in `feather-weapons` or `feather-admin`.

### 9.4 Delivery phases

#### MENU-W1 — Async action primitive

- Add pending-state controls, one-shot callbacks, stale-response guards, and standard error display.

**Exit gate:** repeated clicks cannot issue duplicate mutation requests.

#### MENU-W2 — Reusable interaction elements

- Add confirmation, bounded numeric input, reason input, loading/empty/error states, and stable keyed list updates.

**Exit gate:** weapons workflows can be built without custom unsafe NUI callbacks.

#### MENU-W3 — Lifecycle hardening

- Add character teardown/resource-stop cleanup and accessibility verification.

**Exit gate:** no open menu or pending callback survives character replacement.

### 9.5 Acceptance checklist

- [ ] Pending mutations cannot be double submitted.
- [ ] UI actions carry stable item-instance IDs, never list positions as identity.
- [ ] Late responses do not update a closed/replaced menu.
- [ ] Confirmation and reason inputs validate bounds.
- [ ] Character teardown and resource stop clear focus/state.

---

## 10. `feather-recipe` support plan

### 10.1 Role in the weapons architecture

`feather-recipe` defines a correct fresh install: resource acquisition, database schema, seed data, configuration order, and start order. It must reflect the final supported contracts rather than historical schemas.

### 10.2 Verified current state

- The migration creates characters, inventories, item definitions, owned item rows, key/value item metadata, and a wide `ammo` table keyed by character.
- The metadata values are limited to 100 characters.
- The ammo table stores many ammunition types as character-level columns, which conflicts with the master plan's inventory-item ammunition model.
- The recipe downloads/installs Feather resources but does not yet encode the new dependency-capability gates or weapon definition/seed validation.

### 10.3 Required target changes

- Replace the legacy character-level ammo schema with ammunition item definitions and inventory-item ownership.
- Add the inventory unique-item and metadata-document migrations selected in `INV-W1`.
- Add indexes for item-instance reads, inventory/type queries, metadata revision, and any serial/audit tables owned by weapons.
- Seed weapon, ammunition, attachment, cleaning, repair, and crafting item definitions through idempotent scripts.
- Set weapon items to unique/non-stackable and ammunition to configured stack behavior.
- Add foreign keys and deletion policies consistent with audit retention.
- Define start order: database → core → character → inventory → UI helpers → weapons → admin integrations.
- Add a clean-install validation step that checks required schema and resource capabilities.
- Separate fresh-install SQL from upgrade migrations; no compatibility requirement exists for old weapons data, but dependent-resource migrations must still be explicit and repeatable.

### 10.4 Delivery phases

#### RECIPE-W1 — Schema alignment

- Land inventory foundation migrations.
- Remove the legacy ammo table from fresh installs.
- Add weapon-owned serial/audit tables only after ownership decisions are final.

**Exit gate:** a clean database represents weapons and ammo entirely through inventory items plus approved supplemental records.

#### RECIPE-W2 — Definitions and ordering

- Add idempotent item/category seeds.
- Update resource downloads and start order.
- Add configuration examples and feature flags.

**Exit gate:** a clean recipe install reaches all dependency readiness gates.

#### RECIPE-W3 — Installation test

- Automate schema validation, seed validation, restart, and first vertical-slice smoke test.

**Exit gate:** a blank server can install, create a character, receive/equip/reload a weapon, restart, and reconcile successfully.

### 10.5 Acceptance checklist

- [ ] Fresh install has no character-level ammo columns/table.
- [ ] Weapon definitions seed as unique items.
- [ ] Ammo and attachment definitions seed with correct stack behavior.
- [ ] Migrations are idempotent or version tracked.
- [ ] Resource start order honors readiness dependencies.
- [ ] Clean-install smoke test covers persistence across restart.

---

## 11. `feather-website` support plan

### 11.1 Role in the weapons architecture

The website is the public contract for server owners and resource authors. It must document the actual supported APIs, security boundaries, configuration, installation, and operational recovery.

### 11.2 Verified current state

- Inventory documentation describes generic add/remove, metadata, get/count, and usable-item calls.
- Character documentation primarily exposes a general spawned event.
- Current documentation does not describe unique-item semantics, metadata revisions, transaction behavior, lifecycle ordering, idempotency, post-commit events, or weapons integration.

### 11.3 Required documentation sets

#### Core and character

- Authoritative server identity resolution
- Character session and lifecycle event ordering
- Client-ready versus server-ready distinction
- RPC result, timeout, rate-limit, and cancellation conventions

#### Inventory

- Item definition versus item instance
- Unique versus stack behavior
- Metadata document and revisions
- Transaction API and examples
- Access decision model
- Movement guards and post-commit events
- Error catalog and concurrency examples

#### Weapons

- Installation and dependencies
- Definition authoring and validation
- Weapon/ammo/attachment item models
- Public exports/events and result codes
- Shops, crafting, jobs, admin, storage, and evidence examples
- Security boundary: client intent versus server authority
- Recovery, reconciliation, logging, and troubleshooting

#### Operations

- Clean install and upgrades
- Schema/capability checks
- Resource restart behavior
- Malformed item quarantine and recovery
- Audit/serial lookup and privacy guidance

### 11.4 Delivery phases

#### DOCS-W1 — Contract docs alongside implementation

- Add versioned reference pages as each dependency contract lands.
- Generate or test examples against exported signatures.

**Exit gate:** every public dependency function used by weapons has accurate docs and an error contract.

#### DOCS-W2 — Integration guides

- Add vertical-slice examples for shop, crafting, job issue, storage, and admin.
- Add diagrams for ownership and transaction flows.

**Exit gate:** another resource can create or transfer a weapon without private events or database writes.

#### DOCS-W3 — Release operations

- Add configuration, security, troubleshooting, recovery, and migration runbooks.
- Cross-link recipe and API version requirements.

**Exit gate:** a server operator can diagnose every readiness failure and common reconciliation outcome.

### 11.5 Acceptance checklist

- [ ] No docs recommend direct weapon metadata or ammo-table writes.
- [ ] Examples use server-only APIs and stable IDs.
- [ ] Lifecycle ordering is explicit.
- [ ] Transaction and conflict behavior is explained.
- [ ] All public events are labeled internal, server-only, client, or networked.
- [ ] Documentation version matches resource capability version.

---

## 12. Database and `oxmysql` coordination

`oxmysql` is an external hard dependency rather than a Feather script, so it does not receive a repository work plan here. The supporting scripts must nevertheless validate these capabilities during Phase 0:

- transaction callback/await behavior
- row locking with `SELECT ... FOR UPDATE`
- affected-row and insert-ID semantics
- deadlock/timeout error reporting
- JSON column support for the supported MySQL/MariaDB versions
- isolation-level expectations
- transaction behavior across the inventory and optional weapon audit/serial tables

If atomic commerce requires a currency mutation owned by `feather-core`, either the currency service must accept the same database transaction boundary or the architecture must use a tested reservation/saga contract. A payment debit followed by an independent item grant is not acceptable.

## 13. Resources that should not become weapon dependencies

### `feather-character`

It supplies lifecycle/presentation hooks only. It must not store equipped weapons or ammo.

### `feather-menu` and `feather-progressbar`

They are optional presentation adapters. The weapon domain must remain functional through exports without them.

### `feather-admin`

It is an optional operator client of the weapons API. Weapons must not depend on admin being installed.

### `feather-website` and `feather-recipe`

They are release/install dependencies, not runtime dependencies.

## 14. Integrated delivery sequence

### Foundation milestone A — Contracts

- [ ] Approve shared result/error/mutation context.
- [ ] Approve core character-session/lifecycle contract.
- [ ] Approve inventory unique-item and metadata schema.
- [ ] Approve transaction and post-commit event contract.

**Gate:** contracts are written before any weapon-domain implementation begins.

### Foundation milestone B — Hard dependencies

- [ ] Complete `CORE-W1` and `CORE-W2`.
- [ ] Complete `CHAR-W1` and `CHAR-W2`.
- [ ] Complete `INV-W1`, `INV-W2`, and `INV-W3`.
- [ ] Add dependency capability checks.

**Gate:** a generic unique item can be created, transactionally mutated, moved, and recovered across character sessions.

### Weapons milestone C — First vertical slice

- [ ] One weapon definition, one ammo definition, one unique item instance.
- [ ] Create, equip, reload, persist condition/ammo, logout, restart, reconcile.
- [ ] Exercise inventory conflicts and core session invalidation.

**Gate:** the master plan's recommended vertical slice passes without direct database writes outside owning repositories.

### Integration milestone D — Presentation and administration

- [ ] Complete `PROGRESS-W1/W2`.
- [ ] Complete `MENU-W1/W2` or use a dedicated weapons NUI.
- [ ] Complete `ADMIN-W1/W2/W3`.

**Gate:** all UI/admin flows call the same weapon-domain services and cannot bypass policy.

### Release milestone E — Install and documentation

- [ ] Complete `RECIPE-W1/W2/W3`.
- [ ] Complete `DOCS-W1/W2/W3`.
- [ ] Run clean-install, restart, concurrency, security, and recovery matrices.

**Gate:** a new server can install and operate the complete system from documented, version-matched artifacts.

## 15. Cross-resource test matrix

| Scenario | Core | Character | Inventory | Weapons | Admin/UI | Recipe/docs |
|---|---:|---:|---:|---:|---:|---:|
| Login and first equip | session | client ready | ownership read | native equip | status | install guide |
| Character switch while equipped | invalidate | teardown/new ped | preserve item | unequip/rebuild | close UI | lifecycle docs |
| Concurrent reload requests | correlation | — | lock/transaction | calculate once | pending state | conflict docs |
| Transfer equipped weapon | session | proximity state | guard/move | unequip/policy | confirmation | API example |
| Disconnect during attachment install | cancel | teardown | rollback | reconcile | cleanup | recovery guide |
| Admin confiscation | actor identity | target lifecycle | guarded move | domain action | permission/audit | operator guide |
| Resource restart | readiness | rehydrate ped | persistent state | reconcile | clear/reload | start order |
| Malformed future metadata | logging | — | safe read | quarantine | inspect only | recovery guide |

## 16. Definition of dependency readiness

The dependent Feather scripts are ready for the full weapons build when:

- Core provides a documented, authoritative, session-aware character lifecycle and hardened RPC contract.
- Character selection, switch, death, respawn, and ped replacement expose deterministic presentation hooks.
- Inventory supports unique item instances, versioned metadata, atomic multi-item mutations, concurrency control, access assertions, movement guards, and post-commit events.
- Admin weapon operations use only the public weapons API and every privileged mutation is permission-gated and traceable.
- Progress/menu presentation resolves exactly once, prevents duplicate submissions, and cleans up through lifecycle interruptions.
- The fresh-install recipe uses inventory-item ammunition and installs the correct schema, definitions, capabilities, and resource order.
- Public documentation matches the implemented versions and contains no direct database-write integration guidance.
- The cross-resource test matrix passes on a clean database and after resource/server restarts.

## 17. Immediate next actions

1. Approve the shared result envelope and mutation context.
2. Write the exact core character-session lifecycle specification.
3. Prototype the inventory unique-item metadata document and transaction API.
4. Verify `oxmysql` transaction/locking behavior on the supported database versions.
5. Build a dependency-only test fixture proving create → mutate → move → logout/reconnect before implementing weapon-native behavior.

The inventory prototype is the highest-risk and highest-value next step. It determines whether the weapons system can honor its central guarantee: the database item remains authoritative while every cross-item mutation is atomic and recoverable.
