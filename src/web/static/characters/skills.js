// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

/** @typedef {import('./types.js').Character} Character */

// Prepare these lists before createView discovers the iteration templates.
document.addEventListener('instanceFetched', prepareSkillGroups);

/**
 * @param {Event} event
 */
function prepareSkillGroups(event) {
    const customEvent = /** @type {CustomEvent} */ (event);
    const character = /** @type {Character} */ (customEvent.detail);
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
