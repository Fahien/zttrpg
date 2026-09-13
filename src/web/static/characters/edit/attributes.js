// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

import { showStatus, hideStatus } from '../types.js';
/** @typedef {import('../types.js').Character} Character */
/** @typedef {import('../types.js').CharacterAttribute} CharacterAttribute */
/** @typedef {CharacterAttribute & { pending: number}} CharacterAttributeEdit */

/** @typedef {{ attributes: CharacterAttributeEdit[], attribute_points: number }} AttributesDraft */


/** @typedef {import('../types.js').Character & { edit: AttributesDraft }} CharacterAttributesEdit */

(() => {

    document.addEventListener('instanceFetched', onInstanceFetched);
    document.addEventListener('instanceLoaded', onInstanceLoaded);

    const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-attributes'));
    submitButton.addEventListener('click', onSubmitAttributes);

    /** @type {CharacterAttributesEdit | null} */
    let character = null;

    /**
     * @param {Event} event
     */
    function onInstanceFetched(event) {
        const customEvent = /** @type {CustomEvent} */ (event);
        setCharacter(/** @type {CharacterAttributesEdit} */ (customEvent.detail));
    }

    /**
     * @param {CharacterAttributesEdit} newCharacter
     */
    function setCharacter(newCharacter) {
        if (!newCharacter) {
            console.error('No instance data found.');
            return;
        }
        character = newCharacter;

        if (character.edit == null) {
            let attribute_draft = /** @type {AttributesDraft} */ ({ attributes: character.attributes, attribute_points: character.attribute_points });
            character.edit = attribute_draft;
        }

        for (const attr of character.edit.attributes) {
            attr.pending = 0;
        }
    }

    function onInstanceLoaded() {
        if (character == null) {
            console.error('Character data is not available.');
            return;
        }

        initButtons();

        renderAttributes();
    }

    function initButtons() {
        // Initialize buttons for attribute editing here
        const decrase_buttons = /** @type {NodeListOf<HTMLButtonElement>} */ (document.querySelectorAll(`[data-action="decrease-attribute"]`));
        const increase_buttons = /** @type {NodeListOf<HTMLButtonElement>} */ (document.querySelectorAll(`[data-action="increase-attribute"]`));

        for (const button of decrase_buttons) {
            button.addEventListener('click', onDecreaseAttribute);
        }
        for (const button of increase_buttons) {
            button.addEventListener('click', onIncreaseAttribute);
        }
    }

    /**
     * @param {Event} event
     */
    function onDecreaseAttribute(event) {
        const button = /** @type {HTMLButtonElement} */ (event.currentTarget);
        const attrId = Number(button.dataset.attributeId);
        addAttribute(attrId, -1);
    }

    /**
     * @param {Event} event
     */
    function onIncreaseAttribute(event) {
        const button = /** @type {HTMLButtonElement} */ (event.currentTarget);
        const attrId = Number(button.dataset.attributeId);
        addAttribute(attrId, 1);
    }

    /**
     * @param {number} attrId
     * @param {number} value
     */
    function addAttribute(attrId, value) {
        if (character == null || character.edit == null) {
            return;
        }

        const attr = character.edit.attributes.find(a => a.attribute.id === attrId);
        if (!attr) {
            return;
        }

        if (value > 0 && character.edit.attribute_points > 0) {
            attr.pending += 1;
            character.edit.attribute_points -= 1;
            renderAttributes();
        } else if (value < 0 && attr.pending > 0) {
            attr.pending -= 1;
            character.edit.attribute_points += 1;
            renderAttributes();
        }
    }

    /**
     * Render the attributes and their pending values.
     */
    function renderAttributes() {
        if (character == null || character.edit == null) {
            return;
        }

        for (const attr of character.attributes) {
            const fieldHtml = document.querySelector(`[data-list="edit.attributes"] [data-attribute-id="${attr.attribute.id}"] [data-field="value"]`);
            if (fieldHtml) {
                fieldHtml.textContent = String(attr.value);
            }
        }

        for (const editAttr of character.edit.attributes) {
            const fieldHtml = document.querySelector(`[data-list="edit.attributes"] [data-attribute-id="${editAttr.attribute.id}"] [data-field="pending"]`);
            if (fieldHtml) {
                fieldHtml.textContent = "+ " + String(editAttr.pending);
            }
        }

        const attributePointsField = document.querySelector(`[data-field="edit.attribute_points"]`);
        if (attributePointsField) {
            attributePointsField.textContent = String(character.edit.attribute_points);
        }
    }



    /**
     * Turns pending into a request.
     *
     * On success the server answers with the character as it now is, and the page
     * adopts it whole. On a refusal, the transaction rolled back, so saved is still
     * exactly what the server holds and only pending has to go. On a network
     * failure nothing is known, so pending is kept: a PUT carries absolute values,
     * and sending it again is harmless.
     */
    async function onSubmitAttributes() {
        if (character == null || character.edit == null) {
            return;
        }
    
        const body = [];

        for (const attribute_edit of character.edit.attributes) {
            if (attribute_edit.pending > 0) {
                body.push({
                    attribute: attribute_edit.attribute.id,
                    spent: attribute_edit.spent + attribute_edit.pending,
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
            const response = await fetch(`/characters/${character.id}/attributes`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
            });

            if (response.ok) {
                setCharacter(/** @type {CharacterAttributesEdit} */(await response.json()));
                hideStatus();
            } else {
                // Reset pending changes on refusal.
                for (let attribute of character.edit.attributes) {
                    attribute.pending = 0;
                }
                character.edit.attribute_points = character.attribute_points;
                showStatus(`Attributes not saved: ${await response.text()}`);
            }
        } catch (error) {
            showStatus(`Attributes not saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally {
            submitButton.disabled = false;
            renderAttributes();
        }
    }

})();
