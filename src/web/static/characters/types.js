// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

/** @typedef {{ id: number, short: string }} Attribute */
/** @typedef {{ attribute: Attribute, spent: number, value: number }} CharacterAttribute */
/** @typedef {{ id: number, name: string, attribute: Attribute | null, kind: { name: string, base_chance: boolean } }} Skill */
/** @typedef {{ skill: Skill, trained: boolean, value: number }} CharacterSkill */
/** @typedef {{ attribute: Attribute, die_sides: number | null }} DamageBonus */
/** @typedef {{ attribute: Attribute, min_value: number, max_value: number, modifier: number }} MovementModifier */
/** @typedef {{ attribute: number, min_value: number, die_sides: number }} DamageBonusRule */
/** @typedef {{ min_value: number, max_value: number, base_chance: number }} SkillBaseChance */
/** @typedef {{ id: number, name: string, description: string, skills: Skill[] }} Specialization */
/** @typedef {{ id: number, trained_skill_count: number }} Age */
/** @typedef {{ specializations: Specialization[] }} Profession */
/**
 * @typedef {{
 *  id: number,
 *  kin: { movement: number },
 *  attribute_points: number,
 *  movement: number,
 *  trained_skill_points: number,
 *  creation_complete: boolean,
 *  profession: Profession,
 *  specialization: Specialization | null,
 *  age: Age,
 *  attributes: CharacterAttribute[],
 *  skills: CharacterSkill[],
 *  innate_skills: CharacterSkill[],
 *  core_skills: CharacterSkill[],
 *  secondary_skills: CharacterSkill[],
 *  heroic_skills: CharacterSkill[],
 *  damage_bonuses: DamageBonus[],
 * }} Character
 */

let statusMessage = document.getElementById('status-message');

/**
 * @param {string} message
 */
export function showStatus(message) {
    if (!statusMessage) {
        return;
    }
    statusMessage.textContent = message;
    statusMessage.classList.add('error');
    statusMessage.hidden = false;
}

export function hideStatus() {
    if (!statusMessage) {
        return;
    }
    statusMessage.hidden = true;
    statusMessage.classList.remove('error');
}


export {};
