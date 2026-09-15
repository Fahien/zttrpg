// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

import { showStatus, hideStatus } from '../types.js';
/** @typedef {import('../types.js').Character} Character */
/** @typedef {{ selected_specialization_id: number | null }} SpecializationEdit */
/** @typedef {import('../types.js').Character & { specialization_edit: SpecializationEdit }} CharacterSpecializationEdit */
/** @typedef {{ data: { character: CharacterSpecializationEdit }, update: () => void }} CharacterView */

(() => {
    const options = /** @type {HTMLUListElement} */ (document.getElementById('specialization-options'));
    const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-specialization'));

    /** @type {CharacterSpecializationEdit | null} */
    let character = null;
    /** @type {CharacterView | null} */
    let view = null;
    let saving = false;

    document.addEventListener('instanceFetched', onInstanceFetched);
    document.addEventListener('bindingsReady', onBindingsReady);
    document.addEventListener('characterUpdated', onCharacterUpdated);
    options.addEventListener('change', onSpecializationChange);
    submitButton.addEventListener('click', onSubmitSpecialization);

    /** @param {Event} event */
    function onInstanceFetched(event) {
        setCharacter(/** @type {CharacterSpecializationEdit} */ ((/** @type {CustomEvent} */ (event)).detail));
    }

    /** @param {Event} event */
    function onBindingsReady(event) {
        view = /** @type {CharacterView} */ ((/** @type {CustomEvent} */ (event)).detail);
    }

    /** @param {Event} event */
    function onCharacterUpdated(event) {
        setCharacter(/** @type {CharacterSpecializationEdit} */ ((/** @type {CustomEvent} */ (event)).detail));
    }

    /** @param {CharacterSpecializationEdit} nextCharacter */
    function setCharacter(nextCharacter) {
        character = nextCharacter;
        character.specialization_edit = { selected_specialization_id: null };
    }

    function refreshView() {
        if (!character || !view) return;
        view.data.character = character;
        view.update();
    }

    /** @param {Event} event */
    function onSpecializationChange(event) {
        if (!character || saving || character.creation_status !== 'specialization' ||
            !(event.target instanceof HTMLInputElement) || event.target.name !== 'specialization') return;
        const id = Number(event.target.value);
        if (!Number.isSafeInteger(id)) return;
        character.specialization_edit.selected_specialization_id = id;
    }

    async function onSubmitSpecialization() {
        if (!character || saving || character.creation_status !== 'specialization' ||
            character.specialization_edit.selected_specialization_id === null) return;

        saving = true;
        submitButton.disabled = true;
        for (const input of options.querySelectorAll('input')) input.disabled = true;
        try {
            const response = await fetch(`/characters/${character.id}/specialization`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ specialization: character.specialization_edit.selected_specialization_id }),
            });
            if (!response.ok) {
                showStatus(`Specialization not saved: ${await response.text()}`);
                return;
            }

            const saved = /** @type {CharacterSpecializationEdit} */ (await response.json());
            document.dispatchEvent(new CustomEvent('characterUpdated', { detail: saved }));
            refreshView();
            document.dispatchEvent(new CustomEvent('characterViewUpdated', { detail: character }));
            hideStatus();
        } catch (error) {
            showStatus(`Specialization not saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally {
            saving = false;
            submitButton.disabled = false;
            for (const input of options.querySelectorAll('input')) input.disabled = false;
        }
    }
})();
