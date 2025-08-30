# Copyright Gammadata GmbH. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0

FROM ghcr.io/mikrowerk/odoo-17-official-image:462d8a8

ARG ADDON_PATH="/mnt/extra-addons"

# copy OCA add-ons
COPY oca-account-financial-tools ${ADDON_PATH}
COPY oca-account-reconcile ${ADDON_PATH}
COPY oca-bank-payment ${ADDON_PATH}
COPY oca-partner-contact ${ADDON_PATH}
COPY oca_knowledge/document_url ${ADDON_PATH}/document_url
COPY oca_web/web_remember_tree_column_width ${ADDON_PATH}/web_remember_tree_column_width
COPY oca_web/web_no_bubble ${ADDON_PATH}/web_no_bubble
COPY oca_web/web_save_discard_button ${ADDON_PATH}/web_save_discard_button
COPY oca_web/web_chatter_position ${ADDON_PATH}/web_chatter_position
COPY oca_web/web_save_discard_button ${ADDON_PATH}/web_save_discard_button
# copy Mikrowerk addons
COPY odoo-tom-jobcontrol/jobcontrol ${ADDON_PATH}/jobcontrol
COPY odoo-tom-jobcontrol/mikrowerk_account_payment ${ADDON_PATH}/mikrowerk_account_payment
COPY odoo-tom-jobcontrol/mikrowerk_email_processing ${ADDON_PATH}/mikrowerk_email_processing
COPY odoo-tom-jobcontrol/mikrowerk_e_invoices ${ADDON_PATH}/mikrowerk_e_invoices
COPY odoo-tom-jobcontrol/mikrowerk_eventmanagement ${ADDON_PATH}/mikrowerk_eventmanagement
COPY odoo-tom-jobcontrol/mikrowerk_tom_import ${ADDON_PATH}/mikrowerk_tom_import

# Copy custom addons
COPY griffity_doc_templates/griffity_templates ${ADDON_PATH}/griffity_templates
