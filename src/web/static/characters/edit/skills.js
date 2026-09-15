// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

import { showStatus, hideStatus } from '../types.js';
/** @typedef {import('../types.js').Character} Character */
/** @typedef {import('../types.js').CharacterSkill} CharacterSkill */
/** @typedef {CharacterSkill & { selected: boolean, readonly display_value: number }} SkillDraft */
/** @typedef {{ trained_skill_points: number, core_skills: SkillDraft[] }} SkillsEdit */
/** @typedef {import('../types.js').Character & { skills_edit: SkillsEdit }} CharacterSkillsEdit */
/** @typedef {{ data: { character: CharacterSkillsEdit }, update: () => void }} CharacterView */

(() => {
    const list = /** @type {HTMLUListElement} */ (document.getElementById('skill-checkboxes'));
    const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-skills'));

    /** @type {CharacterSkillsEdit | null} */
    let character = null;
    /** @type {CharacterView | null} */
    let view = null;
    let saving = false;

    document.addEventListener('instanceFetched', onInstanceFetched);
    document.addEventListener('bindingsReady', onBindingsReady);
    document.addEventListener('characterUpdated', onCharacterUpdated);
    document.addEventListener('characterViewUpdated', onCharacterViewUpdated);
    list.addEventListener('change', onSkillCheckboxChange);
    submitButton.addEventListener('click', onSubmitSkills);

    /** @param {Event} event */
    function onInstanceFetched(event) {
        setCharacter(/** @type {CharacterSkillsEdit} */ ((/** @type {CustomEvent} */ (event)).detail));
    }

    /** @param {Event} event */
    function onBindingsReady(event) {
        view = /** @type {CharacterView} */ ((/** @type {CustomEvent} */ (event)).detail);
        renderSkills();
    }

    /** @param {Event} event */
    function onCharacterUpdated(event) {
        setCharacter(/** @type {CharacterSkillsEdit} */ ((/** @type {CustomEvent} */ (event)).detail));
    }

    /** @param {Event} event */
    function onCharacterViewUpdated(event) {
        if ((/** @type {CustomEvent} */ (event)).detail === character) syncSkillControls();
    }

    /** @param {CharacterSkillsEdit} nextCharacter */
    function setCharacter(nextCharacter) {
        character = nextCharacter;
        character.skills_edit = {
            trained_skill_points: character.trained_skill_points,
            core_skills: character.skills
                .filter((entry) => entry.skill.kind.name === 'Core')
                .map((entry) => ({
                    ...entry,
                    selected: false,
                    // The text binding reads this preview without changing the saved value.
                    get display_value() {
                        return this.selected ? this.value * 2 : this.value;
                    },
                })),
        };
    }

    function renderSkills() {
        if (!character || !view) return;
        view.data.character = character;
        view.update();
        syncSkillControls();
    }

    function syncSkillControls() {
        if (!character) return;
        const professionSkillIds = new Set(character.specialization?.skills.map((skill) => skill.id) ?? []);
        for (const entry of character.skills_edit.core_skills) {
            const row = list.querySelector(`[data-skill-id="${entry.skill.id}"]`)?.closest('.skill-row');
            if (!row) continue;
            const checkbox = row.querySelector('input[type="checkbox"]');
            if (checkbox instanceof HTMLInputElement) {
                checkbox.checked = entry.trained || entry.selected;
                checkbox.disabled = entry.trained || saving || character.creation_status !== 'skills';
            }
            const professionMarker = row.querySelector('[data-specialization-skill]');
            if (professionMarker instanceof HTMLElement) professionMarker.hidden = !professionSkillIds.has(entry.skill.id);
            const state = row.querySelector('[data-training-state]');
            if (state instanceof HTMLElement) {
                state.hidden = !entry.trained && !entry.selected;
                state.textContent = entry.trained ? 'Trained' : 'Selected';
            }
        }
        const help = document.getElementById('trained-skill-help');
        if (help) {
            help.textContent = character.creation_status === 'attributes'
                ? 'Spend attribute points before choosing training skills.'
                : character.creation_status === 'specialization'
                ? 'Choose a specialization before choosing training skills.'
                : character.creation_status === 'skills'
                ? `${character.skills_edit.trained_skill_points} training point${character.skills_edit.trained_skill_points === 1 ? '' : 's'} remaining.`
                : 'Training complete.';
        }
    }

    /** @param {Event} event */
    function onSkillCheckboxChange(event) {
        if (!character || saving || character.creation_status !== 'skills' ||
            !(event.target instanceof HTMLInputElement) || event.target.type !== 'checkbox') return;
        const skillId = Number(event.target.value);
        if (!Number.isSafeInteger(skillId)) return;
        const skill = character.skills_edit.core_skills.find((entry) => entry.skill.id === skillId);
        if (!skill || skill.trained) return;

        if (event.target.checked && character.skills_edit.trained_skill_points <= 0) {
            event.target.checked = false;
            return;
        }
        if (!event.target.checked && !skill.selected) return;

        skill.selected = event.target.checked;
        character.skills_edit.trained_skill_points += skill.selected ? -1 : 1;
        renderSkills();
    }

    async function onSubmitSkills() {
        if (!character || saving || character.creation_status !== 'skills') return;
        const skills = character.skills_edit.core_skills
            .filter((entry) => entry.selected)
            .map((entry) => entry.skill.id);

        saving = true;
        submitButton.disabled = true;
        syncSkillControls();
        try {
            const response = await fetch(`/characters/${character.id}/train_skills`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ skills }),
            });
            if (!response.ok) {
                showStatus(`Skills not saved: ${await response.text()}`);
                return;
            }

            const saved = /** @type {CharacterSkillsEdit} */ (await response.json());
            document.dispatchEvent(new CustomEvent('characterUpdated', { detail: saved }));
            renderSkills();
            document.dispatchEvent(new CustomEvent('characterViewUpdated', { detail: character }));
            hideStatus();
        } catch (error) {
            showStatus(`Skills not saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally {
            saving = false;
            submitButton.disabled = false;
            syncSkillControls();
        }
    }
})();
