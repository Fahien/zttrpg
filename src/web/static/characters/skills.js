// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

/** @typedef {{ id: number, short: string }} Attribute */
/** @typedef {{ attribute: Attribute, spent: number, value: number }} CharacterAttribute */
/** @typedef {{ attribute: Attribute | null, id: number, kind: { name: string, base_chance: boolean } }} Skill */
/** @typedef {{ skill: Skill, trained: boolean, value: number }} CharacterSkill */
/** @typedef {{ attribute: Attribute, die_sides: number | null }} DamageBonus */
/**
 * @typedef {{
 *  id: number,
 *  kin: { movement: number },
 *  attribute_points: number,
 *  movement: number,
 *  attributes: CharacterAttribute[],
 *  skills: CharacterSkill[],
 *  innate_skills: CharacterSkill[],
 *  core_skills: CharacterSkill[],
 *  secondary_skills: CharacterSkill[],
 *  heroic_skills: CharacterSkill[],
 *  damage_bonuses: DamageBonus[],
 * }} Character
 */
/** @typedef {{ attribute: Attribute, min_value: number, max_value: number, modifier: number }} MovementModifier */
/** @typedef {{ attribute: number, min_value: number, die_sides: number }} DamageBonusRule */
/** @typedef {{ min_value: number, max_value: number, base_chance: number }} SkillBaseChance */

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
