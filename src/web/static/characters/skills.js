// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

// Saved state of the character: the last answer the server gave, on load and
// after every submit. Nothing in it is ever computed from clicks.
let character = /** @type {Character} */ (/** @type {unknown} */ (null));

document.addEventListener('instanceLoaded', onInstanceLoaded);

// The banner from the header partial, shared with instance.js.
const statusMessage = document.getElementById('status-message');

/**
 * @param {Event} event
 */
function onInstanceLoaded(event) {
    const customEvent = /** @type {CustomEvent} */ (event);
    character = /** @type {Character} */ (customEvent.detail);
    if (!character) {
        console.error('No instance data found in event detail.');
        return;
    }

    character.innate_skills = [];
    character.core_skills = [];
    character.secondary_skills = [];
    character.heroic_skills = [];

    for (const skill of character.skills) {
        if (skill.value == 0) continue;

        if (skill.skill.kind.name === 'Innate') {
            character.innate_skills.push(skill);
        }
        if (skill.skill.kind.name === 'Core') {
            character.core_skills.push(skill);
        }
        if (skill.skill.kind.name === 'Secondary') {
            character.secondary_skills.push(skill);
        }
        if (skill.skill.kind.name === 'Heroic') {
            character.heroic_skills.push(skill);
        }
    }
}
