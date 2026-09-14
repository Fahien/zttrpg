// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

import { showStatus, hideStatus } from '../types.js';
/** @typedef {import('../types.js').Character} Character */
/** @typedef {{ selected_specialization_id: number | null }} SpecializationEdit */
/** @typedef {import('../types.js').Character & { specialization_edit: SpecializationEdit | null }} CharacterSpecializationEdit */

(() => {

    document.addEventListener('instanceFetched', onInstanceFetched);
    document.addEventListener('instanceLoaded', onInstanceLoaded);

    const specializationOptions = /** @type {HTMLElement} */ (document.getElementById('specialization-options'));
    specializationOptions.addEventListener('change', onSpecializationChange);

    const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-specialization'));
    submitButton.addEventListener('click', onSubmitSpecialization);

    /** @type {CharacterSpecializationEdit | null} */
    let character = null;

    /**
     * @param {Event} event
     */
    function onInstanceFetched(event) {
        const customEvent = /** @type {CustomEvent<Character>} */ (event);
        setCharacter(/** @type {CharacterSpecializationEdit} */(customEvent.detail));
    }

    /**
     * @param {CharacterSpecializationEdit} newCharacter
     */
    function setCharacter(newCharacter) {
        if (!newCharacter) {
            console.error('No instance data found.');
            return;
        }
        character = newCharacter;

        if (character.specialization_edit == null) {
            let specialization_draft = /** @type {SpecializationEdit} */ ({ selected_specialization_id: null });
            character.specialization_edit = specialization_draft;
        }
    }

    function onInstanceLoaded() {
        if (character == null) {
            console.error('Character data is not available.');
            return;
        }

        submitButton.addEventListener('click', onSubmitSpecialization);
    }

    /**
     * @returns {Promise<void>}
     */
    async function onSubmitSpecialization() {
        if (character == null || character.specialization_edit == null) {
            return;
        }

        const body = {
            specialization: character.specialization_edit.selected_specialization_id,
        };


        // One request at a time: a second click while this one is in flight would
        // send the same body twice.
        submitButton.disabled = true;
        try {
            const response = await fetch(`/characters/${character.id}/specialization`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
            });

            if (response.ok) {
                setCharacter(/** @type {CharacterSpecializationEdit} */(await response.json()));
                hideStatus();
            } else {
                showStatus(`Specialization not saved: ${await response.text()}`);
            }
        } catch (error) {
            showStatus(`Specialization not saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally {
            submitButton.disabled = false;
        }

    }

    /**
     * @param {Event} event
     */
    function onSpecializationChange(event) {
        if (!character || !character.specialization_edit) {
            return;
        }

        const target = event.target;
        if (!(target instanceof HTMLInputElement) || target.name !== 'specialization') return;
        
        const id = Number(target.value);
        if (!Number.isSafeInteger(id)) return;

        character.specialization_edit.selected_specialization_id = id;
        console.log(`Selected specialization ID: ${id}`);
    }

})();
