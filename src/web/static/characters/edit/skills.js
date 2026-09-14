// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

import { showStatus, hideStatus, fetchConfigValue } from '../types.js';
/** @typedef {import('../types.js').Character} Character */
/** @typedef {import('../types.js').Skill} Skill */
/** @typedef {import('../types.js').CharacterSkill} CharacterSkill */
/** @typedef {{ trained_skill_points: number, core_skills: CharacterSkill[] }} SkillsEdit */
/** @typedef {import('../types.js').Character & { skills_edit: SkillsEdit }} CharacterSkillsEdit */

(() => {
    /** @type {number} */
    let professionSkillMinimum = 0;

    const skillCheckboxes = /** @type {HTMLUListElement} */ (document.getElementById('skill-checkboxes'));
    skillCheckboxes.addEventListener('change', onSkillCheckboxChange);

    document.addEventListener('instanceFetched', onInstanceFetched);
    document.addEventListener('instanceLoaded', onInstanceLoaded);

    const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-skills'));
    submitButton.addEventListener('click', onSubmitSkills);

    /** @type {CharacterSkillsEdit | null} */
    let character = null;

    /**
     * @param {Event} event
     */
    async function onInstanceFetched(event) {
        const customEvent = /** @type {CustomEvent<Character>} */ (event);
        setCharacter(/** @type {CharacterSkillsEdit} */(customEvent.detail));

        professionSkillMinimum = await fetchConfigValue('profession_skill_minimum');
    }

    /**
     * @param {CharacterSkillsEdit} newCharacter
     */
    function setCharacter(newCharacter) {
        if (!newCharacter) {
            console.error('No instance data found.');
            return;
        }
        character = newCharacter;

        if (character.skills_edit == null) {
            let skills_draft = /** @type {SkillsEdit} */ ({ trained_skill_points: character.trained_skill_points, core_skills: [] });
            for (const skill of character.skills) {
                if (skill.skill.kind.name === 'Core') {
                    skills_draft.core_skills.push(skill);
                }
            }
            character.skills_edit = skills_draft;
        }
    }

    function onInstanceLoaded() {
        if (character == null) {
            console.error('Character data is not available.');
            return;
        }

        submitButton.addEventListener('click', onSubmitSkills);
    }

    /**
     * @returns {Promise<void>}
     */
    async function onSubmitSkills() {
        if (character == null || character.skills_edit == null) {
            return;
        }

        const body = {
            skills: character.skills_edit.core_skills,
        };

        // One request at a time: a second click while this one is in flight would
        // send the same body twice.
        submitButton.disabled = true;

        try {
            const response = await fetch(`/characters/${character.id}/train-skills`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
            });

            if (response.ok) {
                setCharacter(/** @type {CharacterSkillsEdit} */(await response.json()));
                hideStatus();
            } else {
                showStatus(`Skills not saved: ${await response.text()}`);
            }
        } catch (error) {
            showStatus(`Skills not saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally {
            submitButton.disabled = false;
        }
    }

    /**
     * @param {Event} event
     */
    async function onSkillCheckboxChange(event) {
        if (character == null || character.skills_edit == null) {
            return;
        }

        const target = /** @type {HTMLInputElement} */ (event.target);
        const skillId = Number(target.value);
        const skill = character.skills_edit.core_skills.find(s => s.skill.id === skillId);
        if (!skill) {
            return;
        }

        if (target.checked && character.skills_edit.trained_skill_points <= 0) {
            target.checked = false;
            return;
        }

        if (!target.checked && character.skills_edit.trained_skill_points == character.trained_skill_points) {
            return;
        }

        skill.trained = target.checked;
        character.skills_edit.trained_skill_points += target.checked ? -1 : 1;

        // Refresh the UI to reflect the updated skill state.
        document.querySelectorAll(`[data-skill-id="${skillId}"]`).forEach(element => {
            const value = skill.trained ? skill.value * 2 : skill.value;
            element.textContent = String(value);
        });

        // Refresh the displayed number of trained skill points.
        document.querySelectorAll('[data-field="skills_edit.trained_skill_points"]').forEach(element => {
            if (character == null || character.skills_edit == null) {
                return;
            }
            element.textContent = String(character.skills_edit.trained_skill_points);
        });
    }

})();
