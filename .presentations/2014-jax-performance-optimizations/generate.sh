#!/bin/sh
asciidoctor -b dzslides -T asciidoctor-backends/slim/dzslides -a linkcss! slides.adoc
