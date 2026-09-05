// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

// Saved state of the character before any attribute points were spent.
let originalCharacter = /** @type {*} */ (null);

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

// The ceiling every value answers to, read from /configs before the stepper is
// shown. The database enforces it as well; knowing it here lets the page
// refuse a click instead of a request.
/** @type {number | null} */
let attributeMax = null;

document.addEventListener('instanceLoaded', onInstanceLoaded);

const list = /** @type {HTMLElement} */ (document.querySelector('[data-list="attributes"]'));
list.addEventListener('click', onAttributeButtonClick);

const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-attributes'));
submitButton.addEventListener('click', onSubmitAttributes);

// The banner from the header partial, shared with instance.js.
const statusMessage = document.getElementById('status-message');

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
    const character = /** @type {*} */ (customEvent.detail);
    if (!character) {
        console.error('No instance data found in event detail.');
        return;
    }

    // Now you can use the instanceData to initialize the attributes update functionality
    initAttributesUpdate(character);
}

/**
 * @param {*} character
 */
async function initAttributesUpdate(character) {
    originalCharacter = character;
    availableAttributePoints = character.attribute_points;

    for (const attr of character.attributes) {
        editAttributeMap.set(attr.attribute.id, 0);
        originalAttributeMap.set(attr.attribute.id, attr.value);
        originalSpentMap.set(attr.attribute.id, attr.spent);
    }

    // The rules come from the same server as the sheet. Without them the
    // stepper stays hidden: a click the page cannot check is not offered.
    try {
        attributeMax = await fetchConfigValue('attribute_max');
    } catch (error) {
        showStatus(`Rules not loaded: ${error instanceof Error ? error.message : String(error)}`);
        return;
    }

    // Everything that spends points stays hidden until there are points to
    // spend. Keyed on the saved pool, not the remaining one: spending the last
    // point before submitting must not hide the pending "+N".
    const hasPoints = character.attribute_points > 0;
    for (const element of document.querySelectorAll('[data-requires-points]')) {
        if (element instanceof HTMLElement) {
            element.hidden = !hasPoints;
        }
    }

    render();
}

/**
 * Reads one rule from the configs resource. Values are stored as text, so a
 * number exists only after this parses one.
 * @param {string} name
 * @returns {Promise<number>}
 */
async function fetchConfigValue(name) {
    const response = await fetch('/configs', { headers: { 'Accept': 'application/json' } });
    if (!response.ok) {
        throw new Error(`${response.status} ${response.statusText}`);
    }

    /** @type {{ name: string, value: string }[]} */
    const configs = await response.json();
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

function render() {
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

    // Nothing pending means nothing to send: the button waits.
    submitButton.disabled = totalPending() === 0;
}

/**
 * 
 * @param {Number} attributeId
 * @returns 
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
 * @param {Number} attributeId 
 * @returns 
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
 * On success, saved absorbs pending. On a refusal, the transaction rolled
 * back, so saved is still exactly what the server holds and only pending has
 * to go. On a network failure nothing is known, so pending is kept: a PUT
 * carries absolute values, and sending it again is harmless.
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
            for (const entry of body) {
                const pending = editAttributeMap.get(entry.attribute) || 0;
                originalAttributeMap.set(entry.attribute, (originalAttributeMap.get(entry.attribute) || 0) + pending);
                originalSpentMap.set(entry.attribute, entry.spent);
                editAttributeMap.set(entry.attribute, 0);
            }
            // Until the server answers with the sheet, the pool is bookkept
            // here: what the server will hold once it debits points.
            originalCharacter.attribute_points = availableAttributePoints;
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
