// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

/** @typedef {{ id: number, short: string }} Attribute */
/** @typedef {{ attribute: Attribute, spent: number, value: number }} CharacterAttribute */
/** @typedef {{ attribute: Attribute | null, id: number, kind: { name: string, base_chance: boolean } }} Skill */
/** @typedef {{ skill: Skill, trained: boolean, value: number }} CharacterSkill */
/** @typedef {{ attribute: Attribute, die_sides: number | null }} DamageBonus */
/** @typedef {{ id: number, kin: { movement: number }, attribute_points: number, movement: number, attributes: CharacterAttribute[], skills: CharacterSkill[], damage_bonuses: DamageBonus[] }} Character */
/** @typedef {{ attribute: Attribute, min_value: number, max_value: number, modifier: number }} MovementModifier */
/** @typedef {{ attribute: number, min_value: number, die_sides: number }} DamageBonusRule */
/** @typedef {{ min_value: number, max_value: number, base_chance: number }} SkillBaseChance */

// Saved state of the character: the last answer the server gave, on load and
// after every submit. Nothing in it is ever computed from clicks.
let originalCharacter = /** @type {Character} */ (/** @type {unknown} */ (null));

let availableAttributePoints = 0;

// Map from attribute id to points added.
// One entry per item in character.attributes, all starting at 0.
let editAttributeMap = new Map();

// Map from attribute id to original value.
let originalAttributeMap = new Map();

// Map from attribute id to points the player has already spent on it. The
// server is told this total, not the value: a value is base plus spent plus
// the rules' modifier, and only spent is the player's to change.
let originalSpentMap = new Map();

// The rules, read from their resources before the stepper is shown. The
// database enforces them as well; knowing them here lets the page refuse a
// click instead of a request, and preview movement and damage bonuses.
/** @type {number | null} */
let attributeMax = null;

/** @type {MovementModifier[] | null} */
let movementModifiers = null;

/** @type {DamageBonusRule[] | null} */
let damageBonusRules = null;

/** @type {SkillBaseChance[] | null} */
let skillBaseChances = null;

document.addEventListener('instanceLoaded', onInstanceLoaded);
document.addEventListener('characterUpdated', onCharacterUpdated);

const list = /** @type {HTMLElement} */ (document.querySelector('[data-list="attributes"]'));
list.addEventListener('click', onAttributeButtonClick);

const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-attributes'));
submitButton.addEventListener('click', onSubmitAttributes);

/**
 * @param {Event} event
 */
function onAttributeButtonClick(event) {
    if (!(event.target instanceof Element)) {
        return;
    }
    const button = (event.target.closest('button[data-action]'));
    if (!(button instanceof HTMLButtonElement)) {
        return;
    }

    const id = Number(button.dataset.attributeId);
    if (isNaN(id)) {
        console.error('Invalid attribute id in button dataset:', button.dataset.attributeId);
        return;
    }

    const action = button.dataset.action;
    if (action === 'increase-attribute') {
        onIncreaseAttribute(id);
    } else if (action === 'decrease-attribute') {
        onDecreaseAttribute(id);
    } else {
        console.error('Unknown action in button dataset:', action);
    }

    render();
}

/**
 * @param {Event} event
 */
function onInstanceLoaded(event) {
    const customEvent = /** @type {CustomEvent} */ (event);
    const character = /** @type {Character} */ (customEvent.detail);
    if (!character) {
        console.error('No instance data found in event detail.');
        return;
    }

    initAttributesUpdate(character);
}

/** @param {Event} event Keeps the attribute step in sync after another creation step saves. */
function onCharacterUpdated(event) {
    const character = /** @type {Character} */ ((/** @type {CustomEvent} */ (event)).detail);
    if (!character) return;
    adoptCharacter(character);
    render();
}

/**
 * @param {Character} character
 */
async function initAttributesUpdate(character) {
    adoptCharacter(character);
    render();

    // The rules come from the same server as the sheet. Without them the
    // stepper stays hidden: a click the page cannot check is not offered.
    try {
        const [max, bands, damageRules, skillBands] = await Promise.all([
            fetchConfigValue('attribute_max'),
            fetchJson('/movement_modifiers'),
            fetchJson('/damage_bonuses'),
            fetchJson('/skill_base_chances'),
        ]);
        attributeMax = max;
        movementModifiers = /** @type {MovementModifier[]} */ (bands);
        damageBonusRules = /** @type {DamageBonusRule[]} */ (damageRules);
        skillBaseChances = /** @type {SkillBaseChance[]} */ (skillBands);
    } catch (error) {
        showStatus(`Rules not loaded: ${error instanceof Error ? error.message : String(error)}`);
    }

    render();
}

/**
 * Takes a character as the server answered it: on load, and after every
 * submit. Saved values replace the old ones and pending starts over.
 * @param {Character} character
 */
function adoptCharacter(character) {
    originalCharacter = character;
    availableAttributePoints = character.attribute_points;

    editAttributeMap.clear();
    originalAttributeMap.clear();
    originalSpentMap.clear();
    for (const attr of character.attributes) {
        editAttributeMap.set(attr.attribute.id, 0);
        originalAttributeMap.set(attr.attribute.id, attr.value);
        originalSpentMap.set(attr.attribute.id, attr.spent);
    }

    // Saved skill values follow an attribute submit as well.
    for (const entry of character.skills) {
        const row = document.querySelector(`[data-skill-id="${entry.skill.id}"]`);
        if (!row) continue;

        const value = row.querySelector('[data-field="value"]');
        if (value) value.textContent = String(entry.value);
    }
}

/**
 * @param {string} path
 * @returns {Promise<unknown>}
 */
async function fetchJson(path) {
    const response = await fetch(path, { headers: { 'Accept': 'application/json' } });
    if (!response.ok) {
        throw new Error(`${path}: ${response.status} ${response.statusText}`);
    }
    return response.json();
}

/**
 * Reads one rule from the configs resource. Values are stored as text, so a
 * number exists only after this parses one.
 * @param {string} name
 * @returns {Promise<number>}
 */
async function fetchConfigValue(name) {
    /** @type {{ name: string, value: string }[]} */
    const configs = /** @type {{ name: string, value: string }[]} */ (await fetchJson('/configs'));
    const config = configs.find((entry) => entry.name === name);
    if (!config) {
        throw new Error(`no config named ${name}`);
    }

    const value = Number(config.value);
    if (Number.isNaN(value)) {
        throw new Error(`config ${name} is not a number: ${config.value}`);
    }
    return value;
}

/**
 * Mirrors deriveMovement in character.zig: the kin's base plus every band the
 * sheet lands in, pending included, so the page previews what a submit will
 * make of it. The server's answer replaces the preview.
 * @param {NonNullable<typeof movementModifiers>} bands
 * @returns {number}
 */
function deriveMovement(bands) {
    let movement = originalCharacter.kin.movement;
    for (const band of bands) {
        const id = band.attribute.id;
        if (!originalAttributeMap.has(id)) {
            continue;
        }
        const value = (originalAttributeMap.get(id) || 0) + (editAttributeMap.get(id) || 0);
        if (value >= band.min_value && value <= band.max_value) {
            movement += band.modifier;
        }
    }
    return movement;
}

/**
 * Selects the highest qualifying threshold, using the saved value plus pending
 * points. Mirrors deriveDamageBonuses in character.zig.
 * @param {number} attributeId
 * @param {NonNullable<typeof damageBonusRules>} rules
 * @returns {number | null}
 */
function deriveDamageBonus(attributeId, rules) {
    const value = (originalAttributeMap.get(attributeId) || 0) + (editAttributeMap.get(attributeId) || 0);
    /** @type {typeof rules[number] | null} */
    let selected = null;
    for (const rule of rules) {
        if (rule.attribute !== attributeId || value < rule.min_value) {
            continue;
        }
        if (selected === null || rule.min_value > selected.min_value) {
            selected = rule;
        }
    }
    return selected === null ? null : selected.die_sides;
}

/**
 * Maps a draft governing attribute to the one skill value shown on the sheet.
 * The multiplier preserves already-saved training during later recalculation.
 * @param {CharacterSkill} entry
 * @param {NonNullable<typeof skillBaseChances>} bands
 */
function deriveSkillValue(entry, bands) {
    const attribute = entry.skill.attribute;
    const hasBaseChance = entry.skill.kind.base_chance;
    if (attribute === null || !hasBaseChance) return entry.value;
    const value = (originalAttributeMap.get(attribute.id) || 0) + (editAttributeMap.get(attribute.id) || 0);
    const band = bands.find((candidate) => value >= candidate.min_value && value <= candidate.max_value);
    return band ? band.base_chance * (entry.trained ? 2 : 1) : entry.value;
}

function render() {
    // Everything that spends points stays hidden until the rules are known and
    // there are points to spend. Keyed on the saved pool, not the remaining
    // one: spending the last point before submitting must not hide the
    // pending "+N".
    const canSpend = attributeMax !== null && movementModifiers !== null && damageBonusRules !== null && originalCharacter.attribute_points > 0;
    for (const element of document.querySelectorAll('[data-requires-points]')) {
        if (element instanceof HTMLElement) {
            element.hidden = !canSpend;
        }
    }

    const attributeList = list.querySelectorAll('li');
    for (const li of attributeList) {
        const attributeId = Number(li.dataset.attributeId);
        if (isNaN(attributeId)) {
            console.error('Invalid attribute id in list item dataset:', li.dataset.attributeId);
            continue;
        }

        const originalValue = li.querySelector('[data-field="value"]');
        if (!originalValue) {
            console.error('No value field found in list item:', li);
            continue;
        }

        originalValue.textContent = String(originalAttributeMap.get(attributeId) || 0);

        const pendingValue = li.querySelector('[data-pending]');
        if (!pendingValue) {
            console.error('No pending field found in list item:', li);
            continue;
        }

        // Empty rather than "+0": an untouched row shows only its saved value.
        const pending = editAttributeMap.get(attributeId) || 0;
        pendingValue.textContent = pending > 0 ? `+${pending}` : '';

        // The buttons show what the handlers would refuse.
        const plus = li.querySelector('button[data-action="increase-attribute"]');
        const minus = li.querySelector('button[data-action="decrease-attribute"]');
        if (plus instanceof HTMLButtonElement) {
            const value = (originalAttributeMap.get(attributeId) || 0) + pending;
            plus.disabled = availableAttributePoints <= 0 || (attributeMax !== null && value >= attributeMax);
        }
        if (minus instanceof HTMLButtonElement) {
            minus.disabled = pending <= 0;
        }
    }

    const availablePointsElement = document.querySelector('[data-field="attribute_points"]');
    if (!availablePointsElement) {
        console.error('No available attribute points element found in the DOM.');
    } else {
        availablePointsElement.textContent = String(availableAttributePoints);
    }

    // Movement follows the sheet as it is edited. With nothing pending the
    // server's own number is shown, so a disagreement between the two
    // derivations could never hide behind the preview.
    const movementElement = document.querySelector('[data-field="movement"]');
    if (movementElement && movementModifiers !== null) {
        const movement = totalPending() === 0 ? originalCharacter.movement : deriveMovement(movementModifiers);
        movementElement.textContent = String(movement);
    }

    // Draft attribute points preview the resulting skill level in the existing
    // value cell; the configuration's base-chance concept stays out of the UI.
    for (const entry of originalCharacter.skills) {
        const value = document.querySelector(`[data-skill-id="${entry.skill.id}"] [data-field="value"]`);
        if (!value) continue;
        value.textContent = String(totalPending() === 0 || skillBaseChances === null
            ? entry.value
            : deriveSkillValue(entry, skillBaseChances));
    }

    // Rebuild from the adopted character so a submit can also change which
    // attributes have bonuses. Saved values remain visible if rules fail to load.
    const damageBonusList = document.getElementById('damage-bonuses');
    if (damageBonusList) {
        damageBonusList.replaceChildren();
        for (const bonus of originalCharacter.damage_bonuses) {
            const sides = totalPending() === 0 || damageBonusRules === null
                ? bonus.die_sides
                : deriveDamageBonus(bonus.attribute.id, damageBonusRules);
            const li = document.createElement('li');
            li.textContent = `${bonus.attribute.short}: ${sides === null ? '-' : `+D${sides}`}`;
            damageBonusList.appendChild(li);
        }
    }

    // Nothing pending means nothing to send: the button waits.
    submitButton.disabled = totalPending() === 0;
}

/**
 * 
 * @param {number} attributeId
 */
function onIncreaseAttribute(attributeId) {
    if (availableAttributePoints <= 0) {
        console.warn('No available attribute points to spend.');
        return;
    }

    const currentPoints = (editAttributeMap.get(attributeId) || 0);

    // The ceiling applies to the total the server will see: saved value, which
    // already includes the age, plus what is pending here.
    const value = (originalAttributeMap.get(attributeId) || 0) + currentPoints;
    if (attributeMax !== null && value >= attributeMax) {
        console.warn(`Attribute ${attributeId} is at the maximum of ${attributeMax}.`);
        return;
    }

    editAttributeMap.set(attributeId, currentPoints + 1);
    availableAttributePoints -= 1;
}

/**
 * 
 * @param {number} attributeId
 */
function onDecreaseAttribute(attributeId) {
    const currentPoints = editAttributeMap.get(attributeId) || 0;
    if (currentPoints <= 0) {
        console.warn('Cannot decrease attribute below 0.');
        return;
    }

    editAttributeMap.set(attributeId, currentPoints - 1);
    availableAttributePoints += 1;
}

/** Points moved by clicks and not yet submitted. */
function totalPending() {
    let total = 0;
    for (const points of editAttributeMap.values()) {
        total += points;
    }
    return total;
}

/**
 * Turns pending into a request: saved plus pending for every touched
 * attribute, sent to the sub-collection the server writes in one transaction.
 *
 * On success the server answers with the character as it now is, and the page
 * adopts it whole. On a refusal, the transaction rolled back, so saved is still
 * exactly what the server holds and only pending has to go. On a network
 * failure nothing is known, so pending is kept: a PUT carries absolute values,
 * and sending it again is harmless.
 */
async function onSubmitAttributes() {
    const body = [];
    for (const [attributeId, pending] of editAttributeMap) {
        if (pending > 0) {
            body.push({
                attribute: attributeId,
                spent: (originalSpentMap.get(attributeId) || 0) + pending,
            });
        }
    }
    if (body.length === 0) {
        return;
    }

    // One request at a time: a second click while this one is in flight would
    // send the same body twice.
    submitButton.disabled = true;
    try {
        const response = await fetch(`/characters/${originalCharacter.id}/attributes`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });

        if (response.ok) {
            adoptCharacter(/** @type {Character} */ (await response.json()));
            document.dispatchEvent(new CustomEvent('characterUpdated', { detail: originalCharacter }));
            hideStatus();
        } else {
            for (const attributeId of editAttributeMap.keys()) {
                editAttributeMap.set(attributeId, 0);
            }
            availableAttributePoints = originalCharacter.attribute_points;
            showStatus(`Attributes not saved: ${await response.text()}`);
        }
    } catch (error) {
        showStatus(`Attributes not saved: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
        render();
    }
}

/**
 * @param {string} message
 */
function showStatus(message) {
    if (!statusMessage) {
        return;
    }
    statusMessage.textContent = message;
    statusMessage.classList.add('error');
    statusMessage.hidden = false;
}

function hideStatus() {
    if (!statusMessage) {
        return;
    }
    statusMessage.hidden = true;
    statusMessage.classList.remove('error');
}
