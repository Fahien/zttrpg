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

document.addEventListener('instanceLoaded', onInstanceLoaded);

const list = /** @type {HTMLElement} */ (document.querySelector('[data-list="attributes"]'));
list.addEventListener('click', onAttributeButtonClick);

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
function initAttributesUpdate(character) {
    originalCharacter = character;
    availableAttributePoints = character.attribute_points;

    // Everything that spends points stays hidden until there are points to
    // spend. Keyed on the saved pool, not the remaining one: spending the last
    // point before submitting must not hide the pending "+N".
    const hasPoints = character.attribute_points > 0;
    for (const element of document.querySelectorAll('[data-requires-points]')) {
        if (element instanceof HTMLElement) {
            element.hidden = !hasPoints;
        }
    }

    for (const attr of character.attributes) {
        editAttributeMap.set(attr.attribute.id, 0);
        originalAttributeMap.set(attr.attribute.id, attr.value);
    }

    render();
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

        pendingValue.textContent = "+" + String(editAttributeMap.get(attributeId) || 0);
    }

    const availablePointsElement = document.querySelector('[data-field="attribute_points"]');
    if (!availablePointsElement) {
        console.error('No available attribute points element found in the DOM.');
    } else {
        availablePointsElement.textContent = String(availableAttributePoints);
    }
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

