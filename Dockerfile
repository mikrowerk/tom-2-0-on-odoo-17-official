# Copyright Gammadata GmbH. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0

# --- Ghostscript 10.x for the PDF/A-3b conversion of reports (mikrowerk_report_pdfa3, TOM-201) ---
# Artifex publishes no Linux binaries any more, so Ghostscript is built from the release source in a
# separate stage and copied into the Odoo image. The bundled third-party libraries (freetype, lcms2,
# libpng, jpeg, zlib, openjpeg) are compiled in; only fontconfig is taken from the system.
FROM ubuntu:jammy AS gs-build
ARG GS_VERSION=10.08.0
ARG GS_TAG=gs10080
ARG GS_SHA256=caf199e3f233f1290b27d0972d636f66c303355f2353309b7bfddf1edda06b3d
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl libfontconfig1-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/ghostscript.tar.gz \
        "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/${GS_TAG}/ghostscript-${GS_VERSION}.tar.gz" \
    && echo "${GS_SHA256}  /tmp/ghostscript.tar.gz" | sha256sum -c - \
    && mkdir -p /tmp/gs && tar -xzf /tmp/ghostscript.tar.gz -C /tmp/gs --strip-components=1 \
    && cd /tmp/gs \
    && ./configure --prefix=/opt/ghostscript --without-x --disable-gtk --disable-cups --without-tesseract \
    && make -j"$(nproc)" \
    && make install \
    && mkdir -p /opt/ghostscript/share/ghostscript/${GS_VERSION}/iccprofiles \
    && cp iccprofiles/*.icc /opt/ghostscript/share/ghostscript/${GS_VERSION}/iccprofiles/ \
    && /opt/ghostscript/bin/gs --version > /opt/ghostscript/VERSION \
    && rm -rf /tmp/gs /tmp/ghostscript.tar.gz

FROM ghcr.io/mikrowerk/tom-2-0-odoo-17-image:6e22768

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
# web_dialog_size: superseded by mikrowerk_widgets (TOM-71); kept in the image until it is
# uninstalled in production, then remove this line
COPY oca_web/web_dialog_size ${ADDON_PATH}/web_dialog_size
COPY oca-purchase-workflow/purchase_mass_mail ${ADDON_PATH}/purchase_mass_mail
COPY oca-social/mail_template_substitute ${ADDON_PATH}/mail_template_substitute
COPY oca-social/mail_optional_autofollow ${ADDON_PATH}/mail_optional_autofollow
# copy third party addons
COPY odoo-tom-third-party-addons/copy_section_with_products ${ADDON_PATH}/copy_section_with_products
COPY odoo-tom-third-party-addons/section_wise_subtotal ${ADDON_PATH}/section_wise_subtotal
# copy Mikrowerk addons: the whole submodule (24 modules since the 2026-09 release);
# non-module entries (README, .update, .features, .claude) are ignored by Odoo
COPY odoo-tom-jobcontrol ${ADDON_PATH}

# Copy custom addons
COPY griffity_doc_templates/griffity_templates ${ADDON_PATH}/griffity_templates
USER root
# Ghostscript from the build stage (see top of file); the version is recorded for support cases.
COPY --from=gs-build /opt/ghostscript /opt/ghostscript
RUN ln -sf /opt/ghostscript/bin/gs /usr/local/bin/gs \
    && gs --version > /etc/gs-version \
    && echo "Ghostscript $(cat /etc/gs-version) installed"
COPY additional-requirements.txt /tmp/additional-requirements.txt
RUN pip3 install -r /tmp/additional-requirements.txt
RUN pip3 install "pyOpenSSL~=22.0.0" "cryptography~=38.0.0"

RUN which pip3 && \
    echo "------------- python module lib before install --------------" && \
    pip3 list

USER odoo
#COPY additional-requirements.txt /tmp/additional-requirements.txt
#RUN pip3 install --user -r /tmp/additional-requirements.txt && \
#    echo "------------- python module lib after install --------------" && \
#    pip3 list
RUN echo "------------- python module lib after install --------------" && \
    pip3 list








