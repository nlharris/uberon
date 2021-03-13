## Customize Makefile settings for uberon
## 
## If you need to customize your Makefile, make
## changes here rather than in the main Makefile

OBO=http://purl.obolibrary.org/obo
CATALOG=catalog-v001.xml
DC = http://purl.org/dc/elements/1.1
DATE = `date +%Y-%m-%d`
RELEASE = $(URIBASE)/uberon/releases/`date +%Y-%m-%d`
QELK = --silence-elk
UCAT = --use-catalog
PART_OF = BFO_0000050
BRIDGEDIR = bridge
CONFIGDIR = config
OWLSRC = $(TMPDIR)/uberon-edit.owl
TAXMODSDIR = taxmods

all: uberon-qc prepare_release clean
	echo "make $@ succeeded..."

# ----------------------------------------
# COMMANDS
# ----------------------------------------

##MAKEOBO= owltools $< --remove-axiom-annotations -o -f obo $@.tmp1 && grep -v ^property_value: $@.tmp1 | grep -v ^owl-axioms: > $@.tmp && obo2obo $@.tmp -o $@
MAKEOBO= owltools $< --add-obo-shorthand-to-properties  -o -f obo --no-check $@.tmp1 && grep -v ^property_value: $@.tmp1 | perl -npe 's@relationship: dc-@property_value: dc-@' | grep -v ^owl-axioms: > $@.tmp && mv $@.tmp  $@

MAKEJSON= owltools $(UCAT) $< --add-obo-shorthand-to-properties  -o -f json $@.tmp && mv $@.tmp $@
MAKEYAML= owltools $(UCAT) $< --add-obo-shorthand-to-properties  -o -f yaml $@.tmp && mv $@.tmp $@

# ----------------------------------------
# TRAVIS TOP LEVEL TARGETS
# ----------------------------------------

# This OWLTools call is designed for running in travis; does not clog stdout
ELKRUN= owltools $(UCAT) $< $(QELK) --run-reasoner -r elk -u > $@.tmp || (tail -1000 $@.tmp && exit -1) && (tail -1000 $@.tmp && mv $@.tmp $@)

# materialize takes too long on travis
#travis_test: ttest-uberon ttest-ext ttest-tax
#TODO @cmungall Current travis test does nearly nothing
travis_test: $(TMPDIR)/is_ok

ttest-uberon: uberon.owl $(REPORTDIR)/bfo-check.txt
	$(ELKRUN)

ttest-ext: ext.owl
	$(ELKRUN)

ttest-tax: $(TMPDIR)/uberon-edit-plus-tax-equivs.owl
	$(ELKRUN)

# ----------------------------------------
# PREP: catalog
# ----------------------------------------
# TODO @cmungall FYI
CATALOG_DYNAMIC=catalog-dynamic.xml
$(CATALOG_DYNAMIC):
	echo "From this day (12 March 2021) forward, $(CATALOG_DYNAMIC) is maintained manually. If you must updated it, plus run 'make update_dynamic_catalog'. Please review the diff carefully as some entries (like ro_import.owl) are omitted by the process."


.PHONY: update_dynamic_catalog
update_dynamic_catalog:
	$(SCRIPTSDIR)/make-catalog.pl uberon.owl ext.owl mirror/ncbitaxon.obo imports/*_import.owl mirror/ro.owl $(TMPDIR)/local-*owl $(BRIDGEDIR)/*owl $(TMPDIR)/allen-*.obo $(TMPDIR)/developmental-stage-ontologies/src/ssso-merged.obo > $@.tmp && mv $@.tmp $@

# ----------------------------------------
# STEP 0: checks
# ----------------------------------------
# NOTE: these are bypassed by travis for now, as some rely on ad-hoc perl

checks: $(REPORTDIR)/uberon-edit-xp-check $(REPORTDIR)/uberon-edit-obscheck.txt \
    $(REPORTDIR)/bfo-check.txt \
    $(REPORTDIR)/uberon.obo-OWL-check \
    $(REPORTDIR)/uberon-obscheck.txt \
    $(REPORTDIR)/uberon-orphans \
    $(REPORTDIR)/uberon-synclash

# ----------------------------------------
# STEP 1: pre-processing and quick validation
# ----------------------------------------

# make edit owl file from previous step, merge in contributors (derived from github API) and expand macros
$(OWLSRC): $(SRC) $(COMPONENTSDIR)/disjoint_union_over.ofn $(REPORTDIR)/$(SRC)-gocheck $(REPORTDIR)/$(SRC)-iconv $(SCRIPTSDIR)/expand-dbxref-literals.pl
	owltools $(UCAT) $< $(COMPONENTSDIR)/disjoint_union_over.ofn issues/contributor.owl --merge-support-ontologies --expand-macros -o  $@.tmp &&  $(SCRIPTSDIR)/expand-dbxref-literals.pl $@.tmp > $@
	
$(TMPDIR)/NORMALIZE.obo: $(SRC)
	$(ROBOT) convert -i $< -o $@.tmp.obo && mv $@.tmp.obo $@

# ----------------------------------------
# STEP 2: preparing core release, and merging with phenoscape edit file
# ----------------------------------------

# core.owl is imported by phenoscape-ext.owl; the two together make up the complete ontology
core.owl: $(OWLSRC)
	owltools $(UCAT) $< -o -f ofn $@

# A portion of uberon is maintained in a separate github repo - we merge that in here
# as part of the release
# TODO is https://raw.githubusercontent.com/obophenotype/uberon-phenoscape-ext/master/phenoscape-ext.owl still the right location?
# TODO review this: maybe not needed anymore? (@balhoff)
$(TMPDIR)/phenoscape-ext.owl: $(SRC)
	wget --no-check-certificate https://raw.githubusercontent.com/obophenotype/uberon-phenoscape-ext/master/phenoscape-ext.owl -O $@ && touch $@

# including the imports would lead to circularity, so we remove these here
$(TMPDIR)/phenoscape-ext-noimports.owl: $(TMPDIR)/phenoscape-ext.owl core.owl
	owltools $(UCAT) $< --remove-imports-declarations -o -f functional $@

# TODO Not used anywhere so commenting out
#$(TMPDIR)/phenoscape_homology.owl:
#	wget --no-check-certificate https://raw.githubusercontent.com/phenoscape/phenoscape-ontologies/master/demo/phenoscape_homology.owl -O $@

## MERGED UNREASONED ONTOLOGY
##
## TODO - restore Disjoints
## TODO - get rid of declarations and inferred subclass axioms for other ontology classes
## TODO: omitting removal of DisjointClasses to see what happens
$(TMPDIR)/unreasoned.owl: $(OWLSRC) $(TMPDIR)/phenoscape-ext-noimports.owl $(BRIDGEDIR)/uberon-bridge-to-bfo.owl 
	owltools $(UCAT) $^ --merge-support-ontologies -o -f functional $@
#	owltools $(UCAT) $^ --merge-support-ontologies --remove-axioms  --remove-axioms -t ObjectPropertyDomain --remove-axioms -t ObjectPropertyRange -o -f functional $@

# First pass at making base module
# Currently this will be missing the temporary reflexivity axioms.
# should this include downward-injected axioms, e.g on ZFA?
uberon-base.owl: $(TMPDIR)/unreasoned.owl
	owltools $(UCAT) $< --remove-imports-declarations --remove-axioms -t Declaration --set-ontology-id -v $(RELEASE)/$@ $(URIBASE)/uberon/$@ -o $@.tmp && mv $@.tmp $@

# ----------------------------------------
# STEP 3: Perform reasoning and create release ext.owl file
# ----------------------------------------

# ext.owl is the release file that includes full imports and inter-ontology axioms
#ext.owl: $(TMPDIR)/materialized.owl
#	$(ROBOT) reason -i $< -r elk relax reduce -r elk annotate -O $(URIBASE)/uberon/$@ -V  $(RELEASE)/$@ -o $@

## TESTING - NEW
$(TMPDIR)/is_ok: $(TMPDIR)/materialized.owl
	owltools $(UCAT) $< --run-reasoner -r elk -u > $@.tmp && mv $@.tmp $@

#TODO Why is materialized.owl annotated? Was this supposed to be released?
$(TMPDIR)/materialized.owl: $(TMPDIR)/unreasoned.owl
	$(ROBOT) --catalog $(CATALOG) relax -i $< materialize -T $(CONFIGDIR)/basic_properties.txt -r elk \
		 reason -r elk --exclude-duplicate-axioms true --equivalent-classes-allowed none \
		 annotate -O $(URIBASE)/uberon/materialized.owl -V  $(RELEASE)/materialized.owl -o $@ 2>&1 > $@.LOG
.PRECIOUS: $(TMPDIR)/materialized.owl

# somewhat awkward: we temporarily inject reflexivity axioms
TMP_REFL=$(COMPONENTSDIR)/reflexivity_axioms.owl
ext.owl: $(TMPDIR)/materialized.owl $(TMP_REFL)
	owltools --use-catalog $< $(TMP_REFL) --merge-support-ontologies -o $(TMPDIR)/m1.owl && \
	$(ROBOT) --catalog $(CATALOG) reduce -i $(TMPDIR)/m1.owl -r elk \
	unmerge -i $(TMP_REFL) \
	annotate -O $(URIBASE)/uberon/$@ -V  $(RELEASE)/$@ -o $@ 2>&1 > $(TMPDIR)/$@.LOG

RELSIM = BFO:0000050 RO:0002202 immediate_transformation_of
# ext.obo is a relation subset of this. TODO: use case?
ext.obo: ext.owl
	owltools $(UCAT) $< --merge-import-closure  -o -f obo --no-check $@.tmp && mv $@.tmp $@
#	owltools $(UCAT) $< --merge-import-closure  --make-subset-by-properties -f $(RELSLIM) // -o -f obo --no-check $@.tmp && mv $@.tmp $@

ext.json: ext.owl
	$(MAKEJSON)

# ----------------------------------------
# STEP 4: Create uberon.owl and .obo
# ----------------------------------------

# merged.owl is now the flattening of ext.owl
# TODO: do we need this intermediate step? Used for subsets
merged.owl: ext.owl
	owltools $(UCAT) $< --merge-import-closure --set-ontology-id -v $(RELEASE)/$@ $(URIBASE)/uberon/$@ -o $@
merged.obo: merged.owl
	owltools $< -o -f obo --no-check $@.tmp && mv $@.tmp $@

# strip imports and dangling references
uberon.owl: ext.owl
	owltools $(UCAT) $< --remove-imports-declarations --remove-dangling --set-ontology-id -v $(RELEASE)/$@ $(URIBASE)/$@ -o $@


# also do OE check here
uberon.obo: uberon.owl
	$(MAKEOBO)

uberon.json: uberon.owl
	$(MAKEJSON)
.PRECIOUS: uberon.json

uberon.yaml: uberon.owl
	$(MAKEYAML)
.PRECIOUS: uberon.yaml

uberon.json.gz: uberon.json
	gzip -c $< > $@.tmp && mv $@.tmp $@


# ----------------------------------------
# STEP 5: Create basic subset
# ----------------------------------------

BASICRELS = BFO:0000050 RO:0002202 immediate_transformation_of transformation_of
# remember to git mv - this replaces uberon-simple
# TODO: ensure relaxation is properly implemented; see for example craniofacial suture
basic.owl:  uberon.owl
	owltools $< --make-subset-by-properties -f $(BASICRELS)  // --set-ontology-id -v $(RELEASE)/$@ $(URIBASE)/uberon/$@ -o $@
basic.obo: basic.owl
	$(MAKEOBO)

subsets/efo-slim.owl: basic.owl
	owltools $< --extract-ontology-subset --subset efo_slim --iri $(URIBASE)/uberon/$@ -o $@
subsets/efo-slim.obo: subsets/efo-slim.owl
	$(MAKEOBO)
subsets/cumbo.owl: basic.owl
	owltools $< --extract-ontology-subset --subset cumbo --iri $(URIBASE)/uberon/$@ -o $@
subsets/cumbo.obo: subsets/cumbo.owl
	$(MAKEOBO)


#TEMPORARY - we will later
#supercheck.owl: $(TMPDIR)/unreasoned.owl
#	owltools $(UCAT) $< $(TMPDIR)/phenoscape-ext-noimports.owl --merge-support-ontologies --expand-macros --assert-inferred-subclass-axioms --useIsInferred -o -f functional $@


# ----------------------------------------
# IMPORTS
# ----------------------------------------

# imports can be built independently of the main release.
# (although pre-processing of the source is done first)
#
# The typical pipeline (see uberon-qc) is to first make imports, then the rest of the release


#TODO - change to include phenoscape-ext

mirror/bspo.owl:
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then $(ROBOT) convert -I $(URIBASE)/cl.owl -o $@.tmp.owl && mv $@.tmp.owl $@; fi
	owltools $(URIBASE)/bspo.owl -o $@; fi

# merge BSPO into RO
mirror/ro.owl: $(OWLSRC) mirror/bspo.owl
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $(URIBASE)/ro.owl mirror/bspo.owl --merge-support-ontologies --merge-imports-closure --add-obo-shorthand-to-properties -o $@ && touch $@; fi

mirror/pato.owl: $(OWLSRC)
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $(URIBASE)/pato.owl --extract-mingraph --make-subset-by-properties -f BFO:0000050 // --set-ontology-id $(URIBASE)/pato.owl -o $@; fi

mirror/go.owl: $(OWLSRC)
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then wget $(URIBASE)/go.owl -O $@ && touch $@; fi

mirror/envo.owl: $(OWLSRC) 
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $(URIBASE)/envo.owl --extract-mingraph --set-ontology-id $(URIBASE)/envo.owl -o $@; fi

mirror/nbo.owl: $(OWLSRC) 
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $(URIBASE)/nbo.owl --extract-mingraph --set-ontology-id $(URIBASE)/nbo.owl -o $@; fi

mirror/chebi.obo: $(OWLSRC)
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then wget --no-check-certificate $(URIBASE)/chebi.obo -O $@.tmp && mv $@.tmp $@ && touch $@; fi

mirror/chebi.owl: $(OWLSRC) mirror/chebi.obo
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools mirror/chebi.obo --extract-mingraph --rename-entity $(URIBASE)/chebi#has_part $(URIBASE)/BFO_0000051 --make-subset-by-properties -f BFO:0000051 //  --set-ontology-id -v $(RELEASE)/chebi.owl $(URIBASE)/chebi.owl -o $@ && touch $@; fi

# Do not rebuild: PR is now too big
# TODO Why this step?
mirror/aminoacid.owl: $(OWLSRC)
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $(URIBASE)/pr.owl  --reasoner-query -r elk PR_000018263 --reasoner-dispose --make-ontology-from-results $(URIBASE)/uberon/aminoacid.owl  -o $@; fi

mirror/pr.owl: mirror/aminoacid.owl
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools mirror/aminoacid.owl --extract-mingraph --rename-entity $(URIBASE)/pr#has_part $(URIBASE)/BFO_0000051 --rename-entity $(URIBASE)/pr#part_of $(URIBASE)/BFO_0000050  --make-subset-by-properties -f BFO:0000050 BFO:0000051 // --split-ontology -d components -l snap --remove-imports-declarations  --remove-dangling --set-ontology-id $(URIBASE)/pr.owl -o $@ && touch $@; fi

mirror/ncbitaxon.obo: 
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then wget $(URIBASE)/ncbitaxon.obo -O $@; fi

$(TMPDIR)/mirror-%: | $(TMPDIR)
	wget --no-check-certificate $(URIBASE)/$* -O $@ && touch $@
.PRECIOUS: $(TMPDIR)/mirror-%

$(TMPDIR)/fixed-emapa.obo: $(TMPDIR)/mirror-emapa.obo | $(TMPDIR)
	$(SCRIPTSDIR)/obo-grep.pl -r 'id: EMAPA' $< | $(SCRIPTSDIR)/fix-emapa-stages.pl  > $@

# stages must be mapped to MmusDv
$(TMPDIR)/developmental-stage-ontologies/src/mmusdv/mmusdv.obo: $(TMPDIR)/update-stages
	test -f $@

mirror/emapa.owl: $(TMPDIR)/fixed-emapa.obo $(TMPDIR)/developmental-stage-ontologies/src/mmusdv/mmusdv.obo
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $(TMPDIR)/fixed-emapa.obo $(TMPDIR)/developmental-stage-ontologies/src/mmusdv/mmusdv.obo --merge-support-ontologies -o -f ofn $@; fi

# https://github.com/obophenotype/uberon/issues/423#issuecomment-43425949
$(TMPDIR)/mirror-zfa.obo:
	wget $(URIBASE)/zfa.obo -O $@

$(TMPDIR)/fixed-zfa.obo: $(TMPDIR)/mirror-zfa.obo
	perl -npe 's@RO:0002488@RO:0002496@;s@RO:0002492@RO:0002497@' $< > $@

mirror/zfa.owl: $(TMPDIR)/fixed-zfa.obo
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $< -o -f ofn $@; fi

$(TMPDIR)/ehdaa2.obo:
	wget $(URIBASE)/ehdaa2.obo -O $@

$(TMPDIR)/fixed-ehdaa2.obo: $(TMPDIR)/ehdaa2.obo | $(SCRIPTSDIR)/obo-grep.pl $(SCRIPTSDIR)/fix-ehdaa2-stages.pl
	$(SCRIPTSDIR)/obo-grep.pl -r 'id: (EHDAA2|AEO)' $< | $(SCRIPTSDIR)/fix-ehdaa2-stages.pl | grep -v ^alt_id > $@

#TODO Whats right here? @cmungall
mirror/ehdaa2.owl: $(TMPDIR)/fixed-ehdaa2.obo
	if [ $(MIR) = true ] && [ $(IMP) = true ]; then owltools $< -o -f ofn $@; fi
	#echo "MAKEERROR-LIKE WARNING: Using some terrible IRI to download.."
	#owltools https://raw.githubusercontent.com/cmungall/human-developmental-anatomy-ontology/uberon/src/ontology/ehdaa2-edit.obo -o -f ofn $@ 

CMUNGALL_OBO_SCRIPTS=https://raw.githubusercontent.com/cmungall/obo-scripts/master/
#$(SCRIPTSDIR)/%.pl:
#	wget $(CMUNGALL_OBO_SCRIPTS)/$*.pl -O $@ && chmod +x $@
#.PRECIOUS: $(SCRIPTSDIR)/%.pl

# These ones are not on Chris script servers so recycling old ones
# $(SCRIPTSDIR)/check-obo-for-standard-release.pl \
# $(SCRIPTSDIR)/expand-dbxref-literals.pl \
# $(SCRIPTSDIR)/expand-idspaces.pl \
# $(SCRIPTSDIR)/fix-ehdaa2-stages.pl \
# $(SCRIPTSDIR)/make-bridge-ontologies-from-xrefs.pl \
# $(SCRIPTSDIR)/allen-json2obo.pl \
# $(SCRIPTSDIR)/mk-vhog-individs.pl:
# 	cp $(SCRIPTSDIR)/util/$(shell basename $@) $@ && chmod +x $@

# We use the branch here: https://github.com/cmungall/human-developmental-anatomy-ontology/tree/uberon
# this has some necessary changes, e.g. https://github.com/cmungall/human-developmental-anatomy-ontology/issues/1


# Note: mirrors are now generated on demand
##mirror-%.owl: $(SRC)

#local-NIF_GrossAnatomy.obo: merged.obo
#	wget http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.owl -O cached-$@.owl && perl -pi -ne 's@http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.owl#@$(URIBASE)/NIF_GrossAnatomy_@g' cached-$@.owl && owltools cached-$@.owl -o -f obo $@




####################################
### Local Ontology dependencies ####
####################################
#TODO Why are these not normal mirrors?

# FEDERATED ONTOLOGY MIRRORING
# TODO removed disjoint axioms from poro, see https://github.com/obophenotype/uberon/issues/1799
$(TMPDIR)/local-poro.owl:
	owltools $(URIBASE)/poro.owl --merge-imports-closure  --remove-axioms -t DisjointClasses --remove-equivalent-to-nothing-axioms --remove-annotation-assertions -l -s -d -o $@
$(TMPDIR)/local-cteno.owl:
	owltools $(URIBASE)/cteno.owl --remove-import-declaration $(URIBASE)/uberon/ext.owl --merge-imports-closure --remove-annotation-assertions -l -s -d -o $@
$(TMPDIR)/local-ceph.owl:
	owltools $(URIBASE)/ceph.owl --remove-import-declaration $(URIBASE)/ceph/imports/uberon_import.owl --merge-imports-closure --remove-annotation-assertions -l -s -d -o $@

# NON-ORTHOGONAL ONTOLOGY MIRRORING

## Map legacy OBO-format ObjectProperties to their BFO/RO intended equivalent
## TODO: many ontologies may have fixed their legacy properties
## TODO: Shouldnt bridge generation be a depenency for this goal? eg $(BRIDGEDIR)/uberon-bridge-to-caro.owl
$(TMPDIR)/local-%.owl: mirror/%.owl
	owltools $< $(BRIDGEDIR)/uberon-bridge-to-caro.owl $(BRIDGEDIR)/cl-bridge-to-caro.owl --rename-entities-via-equivalent-classes --repair-relations \
    --rename-entity $(URIBASE)/$*#develops_in $(URIBASE)/RO_0002203 \
    --rename-entity $(URIBASE)/$*#develops_from $(URIBASE)/RO_0002202 \
    --rename-entity $(URIBASE)/$*#preceded_by $(URIBASE)/RO_0002087 \
    --rename-entity $(URIBASE)/$*#starts_at_end_of $(URIBASE)/RO_0002087 \
    --rename-entity $(URIBASE)/$*#DESCENDENTOF $(URIBASE)/RO_0002476 \
    --rename-entity $(URIBASE)/$*#DESCINMALE $(URIBASE)/RO_0002478 \
    --rename-entity $(URIBASE)/$*#DESCINHERM $(URIBASE)/RO_0002477 \
    --rename-entity $(URIBASE)/$*#connected_to $(URIBASE)/RO_0002170 \
    --rename-entity $(URIBASE)/$*#start $(URIBASE)/RO_0002496 \
    --rename-entity $(URIBASE)/$*#end $(URIBASE)/RO_0002497 \
    --rename-entity $(URIBASE)/$*#start_stage $(URIBASE)/RO_0002496 \
    --rename-entity $(URIBASE)/$*#end_stage $(URIBASE)/RO_0002497 \
    --rename-entity $(URIBASE)/$*#releases_neurotransmitter $(URIBASE)/RO_0002111  \
    --rename-entity $(URIBASE)/$*#develops_directly_from $(URIBASE)/RO_0002207   \
    --rename-entity $(URIBASE)/$*#electrically_synapsed_to $(URIBASE)/RO_0002003 \
    --rename-entity $(URIBASE)/$*#regional_part_of $(URIBASE)/BFO_0000050 \
    --rename-entity $(URIBASE)/$*#systemic_part_of $(URIBASE)/BFO_0000050 \
    --rename-entity $(URIBASE)/$*#constitutional_part_of $(URIBASE)/BFO_0000050\
    --remove-axioms -t DisjointClasses --remove-axioms -t ObjectPropertyRange --remove-axioms -t ObjectPropertyDomain --remove-annotation-assertions -l -s -d -o -f ofn $@

$(TMPDIR)/local-%.obo: $(TMPDIR)/local-%.owl
	owltools $< -o -f obo $@



#seed.tsv: $(TMPDIR)/seed.owl
#	owltools $(USECAT) --extract-

# Import module for RO
#
# No TBox; use an OP seed that is derived from a separate sparql query
imports/ro_import.owl: mirror/ro.owl $(OWLSRC) reports/uberon-edit-object-properties.csv
	$(ROBOT) extract -i $< -m STAR -T reports/uberon-edit-object-properties.csv annotate -O $(URIBASE)/uberon/ro.owl -a $(DC)/title "Relations Ontology Module for Uberon" -o $@.tmp.owl && owltools $@.tmp.owl --remove-tbox --remove-annotation-assertions -l -d -r  -o $@

imports/pato_import.owl: mirror/pato.owl $(OWLSRC) 
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $< $(OWLSRC) --extract-module -s $(URIBASE)/pato.owl -c --extract-mingraph --set-ontology-id -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

# TODO - logical definitions go->ubr,cl
imports/go_import.owl: mirror/go.owl $(OWLSRC) 
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $<  $(OWLSRC) --extract-module -s $(URIBASE)/go.owl -c --extract-mingraph --set-ontology-id  -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

imports/envo_import.owl: mirror/envo.owl $(OWLSRC) 
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $< $(OWLSRC) --extract-module -s $(URIBASE)/envo.owl -c --make-subset-by-properties --force --extract-mingraph --set-ontology-id  -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

imports/nbo_import.owl: mirror/nbo.owl $(OWLSRC) 
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $< $(OWLSRC) --extract-module -s $(URIBASE)/nbo.owl -c --make-subset-by-properties --force  --extract-mingraph --set-ontology-id  -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

imports/chebi_import.owl: mirror/chebi.owl $(OWLSRC) 
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $< $(OWLSRC) --extract-module -s $(URIBASE)/chebi.owl -c --extract-mingraph  --set-ontology-id -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

imports/pr_import.owl: mirror/pr.owl $(OWLSRC) 
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $< $(OWLSRC) --extract-module -s $(URIBASE)/pr.owl -c --extract-mingraph  --set-ontology-id -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

# TODO - use full taxonomy
#ncbitaxon.owl: 
#	OWLTOOLS_MEMORY=14G owltools $(URIBASE)/ncbitaxon.owl -o $@ && touch $@
##	owltools $(URIBASE)/ncbitaxon/subsets/taxslim-disjoint-over-in-taxon.owl --merge-import-closure --make-subset-by-properties -f RO:0002162 // --split-ontology -d null -l cl go caro --remove-imports-declarations --set-ontology-id $(URIBASE)/$@ -o $@
aa:
	owltools $(UCAT) --map-ontology-iri $(ONTBASE)/imports/pr_import.owl mirror/pr.owl $(OWLSRC) --extract-module -s $(URIBASE)/pr.owl -c --extract-mingraph --set-ontology-id -v $(RELEASE)/imports/pr_import.owl $(ONTBASE)/imports/pr_import.owl -o $@


imports/ncbitaxon_import.owl: mirror/ncbitaxon.obo $(OWLSRC) $(TMPDIR)/composite-stages.obo
	OWLTOOLS_MEMORY=14G owltools $(UCAT) --map-ontology-iri $(ONTBASE)/$@ $< $(OWLSRC) $(TMPDIR)/composite-stages.obo --merge-support-ontologies --extract-module -s $(URIBASE)/ncbitaxon.owl -c --extract-mingraph  --remove-dangling-annotations --create-taxon-disjoint-over-in-taxon -s -r NCBITaxon:2759 -m --set-ontology-id -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

# CL - take **everything**
imports/cl_import.owl: $(TMPDIR)/cl-core.obo $(OWLSRC)
	owltools $(UCAT) $<  --set-ontology-id -v $(RELEASE)/$@ $(ONTBASE)/$@ -o $@

%_import.obo: %_import.owl
	owltools $< --add-obo-shorthand-to-properties -o -f obo --no-check $@

imports: imports/pato_import.obo imports/chebi_import.obo imports/pr_import.obo imports/ncbitaxon_import.obo imports/cl_import.obo imports/go_import.obo imports/ro_import.obo
	touch $@

# ----------------------------------------
# MARKDOWN EXPORT
# ----------------------------------------
markdown:
	owltools ext.owl --merge-imports-closure --ontology-to-markdown md

# ----------------------------------------
# REPORTS
# ----------------------------------------
Drerio = NCBITaxon:7955
Xenopus = NCBITaxon:8353
Human = NCBITaxon:9606
Dmel = NCBITaxon:7227
##RPT_TAXA_ARGS = -gp BFO:0000050 -gf $(Drerio) $(Xenopus) $(Human) $(Dmel)
RPT_TAXA_ARGS = 
#RPT_STAGE_RELS = RO:0002488 RO:0002492 RO:0002496 RO:0002497
RPT_STAGE_RELS = RO:0002496 RO:0002497

#%-classes.tsv: %.owl
#	owljs-tableify -R "RO_0002202,transformation of,in taxon,existence starts during,existence ends during" -c -o $@ $<
##	owljs-tableify -R "develops from,in taxon,existence_starts_during,existence ends during" -c -o $@ $<

#%-parents.tsv: %-part-parents.tsv %-dev-parents.tsv %-tax-parents.tsv %-stage-parents.tsv %-function-parents.tsv
#	echo done




reports/%-part-of-parents.tsv: %.owl
	owltools $< --reasoner elk --reasoner mexr --log-error  --export-parents -p BFO:0000050 $(RPT_TAXA_ARGS) -o $@.tmp && mv $@.tmp $@
.PRECIOUS: reports/%-part-of-parents.tsv
reports/%-has-part-parents.tsv: %.owl
	owltools $< --reasoner elk --reasoner mexr --log-error  --export-parents -p BFO:0000051 $(RPT_TAXA_ARGS) -o $@.tmp && mv $@.tmp $@
.PRECIOUS: reports/%-has-part-parents.tsv
reports/%-dev-parents.tsv: %.owl
	owltools $< --reasoner elk --reasoner mexr --export-parents -p RO:0002202 RO:0002494 -o $@.tmp && mv $@.tmp $@
.PRECIOUS: reports/%-dev-parents.tsv
reports/%-tax-parents.tsv: %.owl
	owltools $< --reasoner elk --reasoner mexr --export-parents -p RO:0002162 -o $@.tmp && mv $@.tmp $@
.PRECIOUS: reports/%-tax-parents.tsv
reports/%-stage-parents.tsv: %.owl
	owltools $< --reasoner elk --reasoner mexr --log-error --export-parents -p $(RPT_STAGE_RELS) $(RPT_TAXA_ARGS) -o $@.tmp && mv $@.tmp $@
.PRECIOUS: reports/%-stage-parents.tsv
reports/%-function-parents.tsv: %.owl
	owltools $< --reasoner elk --reasoner mexr --export-parents -p RO:0002328 -o $@.tmp && mv $@.tmp $@
.PRECIOUS: reports/%-function-parents.tsv

reports/uberon-%.csv: uberon.owl ../sparql/%.sparql
	$(ROBOT) query -i $< --query ../sparql/$*.sparql  $@.tmp && $(SCRIPTSDIR)/curiefy-purls.pl $@.tmp > $@ && rm $@.tmp

reports/uberon-edit-%.csv: $(OWLSRC) ../sparql/%.sparql
	$(ROBOT) query -i $< --query ../sparql/$*.sparql  $@.tmp && $(SCRIPTSDIR)/curiefy-purls.pl $@.tmp > $@ && rm $@.tmp

# nh-% : no -homology relations
#
# match pattern for any relation to be filtered out
XSPECIES_RE = -m '/(RO_0002158|evolved_from)/'
nh-%.obo: composite-%.owl
	owltools $< -o -f obo --no-check $@.tmp && egrep -v 'relationship: (homologous_to|evolved_from)' $@.tmp > $@

nh-%.owl: nh-%.obo
	owltools $< -o $@.tmp && mv $@.tmp $@



#nh-human.owl: composite-human.owl
#	owljs-grep -v $(XSPECIES_RE) -o $@ $<

#nh-mouse.owl: composite-mouse.owl
#	owljs-grep -v $(XSPECIES_RE) -o $@ $<

#nh-zebrafish.owl: composite-zfa.owl
#	owljs-grep -v $(XSPECIES_RE) -o $@ $<

#nh-xenopus.owl: composite-xenopus.owl
#	owljs-grep -v $(XSPECIES_RE) -o $@ $<

#nh-drosophila.owl: composite-fbbt.owl
#	owljs-grep -v $(XSPECIES_RE) -o $@ $<

#nh-nematode.owl: composite-wbbt.owl
#	owljs-grep -v $(XSPECIES_RE) -o $@ $<

metazoan-view.owl: ext.owl
	ln -s $< $@ 

# run the reasoner, set to remove unsatisfiable classes (ie those not in the species specified in the context)
#ext-taxon-axioms.owl 
subsets/%-view.owl: ext.owl contexts/context-%.owl
	OWLTOOLS_MEMORY=14G owltools --use-catalog $< contexts/context-$*.owl --merge-support-ontologies --merge-imports-closure $(QELK) --set-ontology-id  $(URIBASE)/$@ --run-reasoner -r elk -x -o -f ofn $@
.PRECIOUS: subsets/%-view.owl

subsets/%-view.obo: subsets/%-view.owl
	owltools --use-catalog $< -o -f obo --no-check $@.tmp && grep -v ^owl $@.tmp > $@

# note: drosophila too slow....
#RPT_SPECIES = human mouse zebrafish xenopus
RPT_SPECIES = human mouse xenopus metazoan

reports/stages: $(patsubst %,reports/stages-%-report.tsv,$(RPT_SPECIES))
	echo done
reports/parts: $(patsubst %,reports/part-%-report.tsv,$(RPT_SPECIES))
	echo done

reports/stages-%-report.tsv: subsets/%-view.owl
	owltools --use-catalog $<  --reasoner mexr --export-parents -p $(RPT_STAGE_RELS) -o $@.tmp && mv $@.tmp $@

# experimental....

branches: reports/branches-nerve.png reports/branches-artery.png

#TODO @cmungall
reports/branches-%.png:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -r uberon ontol-subset -query "class(R,$*),parent(ID,branching_part_of,_),subclassT(ID,R)" -rel branching_part_of -to png -cr branching_part_of > $@.tmp && mv $@.tmp $@

#TODO @cmungall
reports/circo-bones.dot:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -r uberon ontol-subset -query "class(R,'bone element'),subclassT(ID,R)" -rel connected_to -to dot > $@.tmp && mv $@.tmp $@

#TODO @cmungall
reports/circo-head-muscles.dot:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -r uberonp ontol-subset -query "class(R,'craniocervical muscle'),subclassT(ID,R)"  -rel attaches_to -rel connected_to -down 1 -to dot > $@.tmp && mv $@.tmp $@
##	blip -r uberonp ontol-subset -query "class(R,'muscle organ'),subclassT(ID,R),parent_over_nr(part_of,ID,'UBERON:0007811')"  -rel attaches_to -rel connected_to -down 1 -to dot > $@.tmp && mv $@.tmp $@

reports/circo-%.png: reports/circo-%.dot
	circo -o$@ -Tpng $<



# ----------------------------------------
# EXTRACT TCs
# ----------------------------------------

# experimental: for propagation to GO
$(TMPDIR)/uberon-taxon-constraints.obo: $(SRC)
	obo-filter-relationships.pl -t only_in_taxon -t never_in_taxon $<  | obo-filter-tags.pl -t id -t name -t relationship - | $(SCRIPTSDIR)/obo-grep.pl --noheader -r relationship: - > $@.tmp && cat $@.tmp taxon-relations.obo > $@

$(TMPDIR)/uberon-taxon-constraints.owl: $(TMPDIR)/uberon-taxon-constraints.obo
	owltools $< --expand-macros -o $@

# ----------------------------------------
# SYNTACTIC CHECKS
# ----------------------------------------

# mostly for checking OBO files
# the outputs of these targets are not consumed, used only for diagnostics

%.obo-allchecks: $(REPORTDIR)/%.obo-OWL-check $(REPORTDIR)/%.obo-gocheck $(REPORTDIR)/%.obo-iconv

# check OBO-Edit can parse the .obo output
# @Deprecated
#%.obo-OE-check: %.obo
#	obo2obo -o $@ $<

# check OWLAPI can parse the .obo output
$(REPORTDIR)/%.obo-OWL-check: %.obo
	owltools $<

# test any file for non UTF-8 characters
$(REPORTDIR)/%-iconv: %
	iconv -f UTF-8 -t ISO-8859-15 $< > $@

# run subset of syntax and structure checks used by GO
# (see .travis.yml for dependencies)

DISABLE= multiply-labeled-edge valid-id-space isa-incomplete ascii-check has-definition bad-pmid ontology-declaration-check referenced-id-syntax-check owl-axiom-check is-symmetric-check
$(REPORTDIR)/%.obo-gocheck: %.obo $(TMPDIR)/GO.xrf_abbs | $(SCRIPTSDIR)/check-obo-for-standard-release.pl
	$(SCRIPTSDIR)/check-obo-for-standard-release.pl --xref-abbs $(TMPDIR)/GO.xrf_abbs $(patsubst %,--disable-%,$(DISABLE)) $< > $@.tmp && mv $@.tmp $@

$(TMPDIR)/GO.xrf_abbs: $(SRC)
	wget http://geneontology.org/doc/GO.xrf_abbs -O $@ && touch $@

# ----------------------------------------
# Taxonomy and external AO validation
# ----------------------------------------

# first generate a merged ontology consisting of
#  * core uberon
#  * external-disjoints.owl
#  * species anatomy bridge axioms
# This can be used to reveal both internal inconsistencies within uberon, and the improper linking of a species AO class to an uberon class with a taxon constraint
$(TMPDIR)/uberon-edit-plus-tax-equivs.owl: $(OWLSRC) $(TMPDIR)/external-disjoints.owl $(BRIDGEDIR)/bridges $(CATALOG_DYNAMIC)
	owltools --catalog-xml $(CATALOG_DYNAMIC) $< $(TMPDIR)/external-disjoints.owl `ls $(BRIDGEDIR)/uberon-bridge-to-*.owl | grep -v emap.owl` --merge-support-ontologies -o -f ofn $@
.PRECIOUS: $(TMPDIR)/uberon-edit-plus-tax-equivs.owl

# see above
$(REPORTDIR)/taxon-constraint-check.txt: $(TMPDIR)/uberon-edit-plus-tax-equivs.owl $(CATALOG_DYNAMIC)
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(QELK) --run-reasoner -r elk -u > $@.tmp && mv $@.tmp $@

# BRIDGE CHECKS.
# these can be used to validate on a per-bridge file basis. There are a variety of flavours:
#
# * quick bridge tests ignore the axioms in the external ontology (but include the bridge axioms themselves)
# * standard bridge tests use the logical axioms in the external ontology
# * full bridge tests do the above using the constructed ext ontology
# * extra full bridge tests also throw in the set of all pending disjoints. Only 'gold star' external ontologies will pass this.
#
# note at this time we don't expect all full-bridge tests to pass. This is because the disjointness axioms are
# very strong and even seemingly minor variations in representation across ontologies can lead to unsatisfiable classes
#
## CHECK_AO_LIST = ma emapa ehdaa2 zfa xao fbbt wbbt
## CHECK_AO_LIST = ma emapa zfa xao fbbt wbbt wbls
#####  CHECK_AO_LIST = ma emapa zfa xao fbbt wbls : Add MA back to list when this is solved; https://sourceforge.net/p/obo/mouse-anatomy-requests/94/

# gold glub 
EXTRA_FULL_CHECK_AO_LIST = caro

# silver club
FULL_CHECK_AO_LIST = $(EXTRA_FULL_CHECK_AO_LIST)  wbls wbbt

# premier execs
CHECK_AO_LIST = $(FULL_CHECK_AO_LIST)

# economy
QUICK_CHECK_AO_LIST = $(CHECK_AO_LIST) fbbt zfa xao fma  ma emapa bfo

quick-bridge-checks: $(patsubst %,$(REPORTDIR)/quick-bridge-check-%.txt,$(FULL_CHECK_AO_LIST))
bridge-checks: $(patsubst %,$(REPORTDIR)/bridge-check-%.txt,$(CHECK_AO_LIST))
full-bridge-checks: $(patsubst %,$(REPORTDIR)/full-bridge-check-%.txt,$(CHECK_AO_LIST))
extra-full-bridge-checks: $(patsubst %,$(REPORTDIR)/extra-full-bridge-check-%.txt,$(EXTRA_FULL_CHECK_AO_LIST))

##$(REPORTDIR)/bfo-check.txt: $(TMPDIR)/uberon-edit-plus-tax-equivs.owl
#TODO @cmungall
$(REPORTDIR)/bfo-check.txt: $(OWLSRC) $(CATALOG_DYNAMIC)
	echo "STRONG WARNING check $@ FAIL currently!"
	OWLTOOLS_MEMORY=14G owltools $(URIBASE)/bfo.owl $(URIBASE)/ro.owl --catalog-xml $(CATALOG_DYNAMIC) $< $(BRIDGEDIR)/uberon-bridge-to-bfo.owl  --merge-support-ontologies -o $(REPORTDIR)/bfo-check.owl $(QELK) --run-reasoner -r elk -u > $@.tmp || true

bfo-basic-check.txt: basic.owl $(CATALOG_DYNAMIC)
	OWLTOOLS_MEMORY=14G owltools   $(URIBASE)/bfo.owl --catalog-xml $(CATALOG_DYNAMIC) $< $(BRIDGEDIR)/uberon-bridge-to-bfo.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u > $@.tmp && mv $@.tmp $@

# A quick bridge check uses only uberon plus taxon constraints plus bridging axioms, *not* the axioms in the source ontology itself
$(REPORTDIR)/quick-bridge-check-%.txt: $(TMPDIR)/uberon-edit-plus-tax-equivs.owl $(BRIDGEDIR)/bridges $(TMPDIR)/external-disjoints.owl $(TMPDIR)/local-%.owl $(CATALOG_DYNAMIC)
	owltools  --catalog-xml $(CATALOG_DYNAMIC) $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u > $@.tmp && mv $@.tmp $@

aaa: 
	make IMP=false PAT=false MIR=false $(REPORTDIR)/quick-bridge-check-caro.txt

# A bridge check uses uberon (no TCs) plus external ontology and the bridge
$(REPORTDIR)/bridge-check-%.owl: uberon.owl $(BRIDGEDIR)/bridges $(TMPDIR)/external-disjoints.owl $(TMPDIR)/local-%.owl $(CATALOG_DYNAMIC)
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(TMPDIR)/local-$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-support-ontologies -o -f ofn $@
.PRECIOUS: $(REPORTDIR)/bridge-check-%.owl
$(REPORTDIR)/bridge-check-%.txt: $(REPORTDIR)/bridge-check-%.owl $(CATALOG_DYNAMIC)
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(QELK) --run-reasoner -r elk -u > $@.tmp && mv $@.tmp $@

#TODO @cmungall
$(REPORTDIR)/bridge-check-caro.txt: |  $(CATALOG_DYNAMIC)
	echo "STRONG WARNING $@ currently set to NOT FAIL because of unsatisfiable classes!"
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(QELK) --run-reasoner -r elk -u > $@ || true


$(REPORTDIR)/expl-bridge-check-%.txt: $(REPORTDIR)/bridge-check-%.owl $(CATALOG_DYNAMIC)
	owltools  --catalog-xml $(CATALOG_DYNAMIC) $< $(QELK) --run-reasoner -r elk -u -e > $@.tmp && mv $@.tmp $@

# A full bridge check uses ext plus external ontology and the bridge
$(REPORTDIR)/full-bridge-check-%.txt: ext.owl $(BRIDGEDIR)/bridges $(TMPDIR)/external-disjoints.owl $(CATALOG_DYNAMIC)
	OWLTOOLS_MEMORY=14G owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u -m $(REPORTDIR)/debug-full-bridge-check-$*.owl  > $@.tmp && mv $@.tmp $@

#TODO @cmungall
$(REPORTDIR)/full-bridge-check-caro.txt: |  $(CATALOG_DYNAMIC)
	echo "STRONG WARNING $@ currently set to NOT FAIL because of unsatisfiable classes!"
	OWLTOOLS_MEMORY=14G owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u -m $(REPORTDIR)/debug-full-bridge-check-$*.owl  > $@ || true

#TODO @cmungall
$(REPORTDIR)/full-bridge-check-wbls.txt: | $(CATALOG_DYNAMIC)
	echo "STRONG WARNING $@ currently set to NOT FAIL because of unsatisfiable classes!"
	OWLTOOLS_MEMORY=14G owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u -m $(REPORTDIR)/debug-full-bridge-check-$*.owl  > $@ || true

#TODO @cmungall
$(REPORTDIR)/full-bridge-check-wbbt.txt: | $(CATALOG_DYNAMIC)
	echo "STRONG WARNING $@ currently set to NOT FAIL because of unsatisfiable classes!"
	OWLTOOLS_MEMORY=14G owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u -m $(REPORTDIR)/debug-full-bridge-check-$*.owl  > $@ || true

# As above, but include pending disjoints. This is a very strict check and we don't expect this to pass for lots of ssAOs.
$(REPORTDIR)/extra-full-bridge-check-%.txt: ext.owl $(TMPDIR)/local-%.owl $(BRIDGEDIR)/uberon-bridge-to-%.owl $(COMPONENTSDIR)/pending-disjoints.obo $(TMPDIR)/external-disjoints.owl $(CATALOG_DYNAMIC)
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $^  --merge-support-ontologies $(QELK) --run-reasoner -r elk -u $(ROPTS) > $@.tmp && mv $@.tmp $@

#TODO @cmungall
$(REPORTDIR)/extra-full-bridge-check-caro.txt: | $(CATALOG_DYNAMIC)
	echo "STRONG WARNING $@ currently set to NOT FAIL because of unsatisfiable classes!"
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $^  --merge-support-ontologies $(QELK) --run-reasoner -r elk -u $(ROPTS) > $@ || true


# @Deprecated
$(REPORTDIR)/core-bridge-check-%.txt: core.owl $(BRIDGEDIR)/bridges $(TMPDIR)/external-disjoints.owl $(CATALOG_DYNAMIC)
	owltools --no-debug --catalog-xml $(CATALOG_DYNAMIC) $< $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-support-ontologies $(QELK) --run-reasoner -r elk -u > $@.tmp && mv $@.tmp $@

# for debugging:
$(TMPDIR)/ext-merged-%.owl: ext.owl $(BRIDGEDIR)/bridges $(TMPDIR)/external-disjoints.owl $(CATALOG_DYNAMIC)
	owltools --catalog-xml $(CATALOG_DYNAMIC) $< $(URIBASE)/$*.owl $(BRIDGEDIR)/uberon-bridge-to-$*.owl $(TMPDIR)/external-disjoints.owl --merge-imports-closure  --merge-support-ontologies -o $@
.PRECIOUS: $(TMPDIR)/ext-merged-%.owl
	
#TODO @cmungall this is never used
$(REPORTDIR)/bridge-dv-check-%.txt: $(TMPDIR)/ext-merged-%.owl
	owltools --no-debug $< --reasoner elk --check-disjointness-axioms  > $@.tmp && mv $@.tmp $@


# check for dangling classes
# TODO: add to Oort
$(REPORTDIR)/%-orphans: %.obo
	$(SCRIPTSDIR)/obo-grep.pl --neg -r "(is_a|intersection_of|is_obsolete):" $< | $(SCRIPTSDIR)/obo-grep.pl -r Term - | $(SCRIPTSDIR)/obo-grep.pl --neg -r "id: UBERON:(0001062|0000000)" - | $(SCRIPTSDIR)/obo-grep.pl -r Term - > $@.tmp && (egrep '^(id|name):'  $@.tmp > $@ || echo ok)



# TODO: add to Oort
$(REPORTDIR)/%-xp-check: %.obo
	$(SCRIPTSDIR)/obo-check-xps.pl $< > $@ 2> $@.err || (echo "problems" && exit 1)

# See: http://douroucouli.wordpress.com/2012/07/03/45/
# TODO - make the OWL primary
# TODO what is depictions.owl @cmungall
depictions.omn: $(SRC)
	$(SCRIPTSDIR)/mk-image-ont.pl $< > $@
depictions.owl: depictions.omn
	owltools $< -o file://`pwd`/$@

QC_FILES = checks\
    core.owl\
    uberon.owl\
    uberon.obo\
    uberon.json\
    $(TMPDIR)/external-disjoints.owl\
    depictions.owl\
    $(BRIDGEDIR)/bridges\
    quick-bridge-checks\
    bridge-checks\
    full-bridge-checks\
    extra-full-bridge-checks\
    $(REPORTDIR)/taxon-constraint-check.txt\
    uberon.owl\
    uberon-base.owl\
    basic.obo\
    basic.json\
    $(REPORTDIR)/basic-allcycles\
    $(REPORTDIR)/basic-orphans\
    $(REPORTDIR)/merged-orphans\
    ext.owl\
    ext.obo\
    ext.json\
    $(REPORTDIR)/ext-obscheck.txt\
    subsets/efo-slim.obo\
    subsets/cumbo.obo\
    subsets/human-view.obo\
    subsets/human-view.owl\
    subsets/mouse-view.obo\
    subsets/mouse-view.owl\
    $(REPORTDIR)/uberon-dv.txt\
    composites\
    composite-metazoan-basic.obo\
    $(REPORTDIR)/composite-metazoan-dv.txt\
    reports/stages\
    all_taxmods\
#    depictions.owl\


# TODO uberon-discv.txt has been removed no recipe
uberon-qc: imports $(QC_FILES) all_subsets
	cat $(REPORTDIR)/merged-orphans $(REPORTDIR)/uberon-edit-obscheck.txt  $(REPORTDIR)/uberon-edit-xp-check.err  $(REPORTDIR)/uberon-orphans $(REPORTDIR)/uberon-synclash $(REPORTDIR)/uberon-dv.txt $(REPORTDIR)/composite-metazoan-dv.txt 


# Disjoint violations
$(REPORTDIR)/%-dv.txt: %.owl
	owltools --no-debug $<  $(QELK) --run-reasoner -r elk -u > $@.tmp && grep UNSAT $@.tmp > $@


# TODO - need closure for taxslim too
$(REPORTDIR)/%-obscheck.txt: %.obo
	(($(SCRIPTSDIR)/obo-map-ids.pl --ignore-self-refs --use-consider --use-replaced_by $< $<) > /dev/null) 2>&1 > $@


# ----------------------------------------
# SUBSETS
# ----------------------------------------
# System-specific subsets

#PA = phenoscape-vocab/phenoscape-anatomy.obo

TERM_nephron := UBERON:0001285
TERM_musculoskeletal := UBERON:0002204
TERM_excretory := UBERON:0001008
TERM_reproductive := UBERON:0000990
TERM_digestive := UBERON:0001007
TERM_nervous := UBERON:0001016
TERM_sensory := UBERON:0004456
TERM_immune := UBERON:0002405
TERM_circulatory := UBERON:0001009
TERM_pulmonary := UBERON:0001004
TERM_cranial := UBERON:0010323
TERM_renal := UBERON:0001008
TERM_appendicular := UBERON:0002091

SYSTEMS = musculoskeletal excretory nephron reproductive digestive nervous sensory immune circulatory pulmonary cranial renal appendicular

all_subsets: all_systems subsets/life-stages-composite.obo subsets/life-stages-core.obo subsets/life-stages-core.owl 
all_systems: all_systems_obo all_systems_owl  all_systems_json all_systems_tsv
all_systems_obo: $(patsubst %,subsets/%-minimal.obo,$(SYSTEMS))
all_systems_owl: $(patsubst %,subsets/%-minimal.owl,$(SYSTEMS))
all_systems_tsv: $(patsubst %,subsets/%-minimal.tsv,$(SYSTEMS))
all_systems_json: $(patsubst %,subsets/%-minimal.json,$(SYSTEMS))


subsets/merged-partonomy.owl: merged.owl
	$(ROBOT) remove --input $< --axioms "equivalent disjoint type abox" \
              remove --exclude-term BFO:0000050 --select "object-properties" \
	      -o $@
.PRECIOUS: subsets/merged-partonomy.owl


subsets/%-minimal.owl: subsets/merged-partonomy.owl
	$(eval TERM_ID := $(TERM_$*))
	owltools $< --reasoner-query -r elk -d  "$(PART_OF) some $(TERM_ID)" --reasoner-query $(TERM_ID) --make-ontology-from-results $(URIBASE)/uberon/$@ -o $@  2>&1 > $@.LOG
.PRECIOUS: subsets/%-minimal.owl
subsets/%-minimal.obo: subsets/%-minimal.owl
	$(ROBOT) convert -i $< --check false -o $@.tmp.obo && mv $@.tmp.obo $@
subsets/%-minimal.json: subsets/%-minimal.owl
	$(ROBOT) convert -i $< --check false -o $@.tmp.json && mv $@.tmp.json $@
subsets/%-minimal.tsv: subsets/%-minimal.owl
	$(ROBOT) export -i $< -c "ID|label|SYNONYMS"  -e $@.tmp && mv $@.tmp $@

# TODO: need to add subclass axioms for all intersections
subsets/musculoskeletal-full.obo: merged.owl
	owltools $< --reasoner-query -r elk -d -c $(URIBASE)/uberon/$@ "$(PART_OF) some UBERON_0002204" -o -f obo file://`pwd`/$@  --reasoner-dispose

subsets/vertebrate-head.obo: composite-vertebrate.owl
	owltools $< --reasoner-query -r elk -d  "$(PART_OF) some UBERON_0000033" --make-ontology-from-results $(URIBASE)/uberon/$@ -o -f obo --no-check $@ --reasoner-dispose 2>&1 > $@.LOG

# TODO - switch to purls for OWL once released
subsets/subsets/life-stages-mammal.owl: subsets/life-stages-core.owl $(TMPDIR)/developmental-stage-ontologies/src/mmusdv/mmusdv.obo $(TMPDIR)/developmental-stage-ontologies/src/hsapdv/hsapdv.obo
	owltools $< $(TMPDIR)/developmental-stage-ontologies/src/mmusdv/mmusdv.obo $(TMPDIR)/developmental-stage-ontologies/src/hsapdv/hsapdv.obo --merge-support-ontologies -o file://`pwd`/$@

#subsets/life-stages.obo: uberon.owl
#subsets/life-stages.obo: composite-metazoan.obo
subsets/life-stages-composite.obo: composite-metazoan.owl
	owltools $< --reasoner-query -r elk -l 'life cycle stage' --make-ontology-from-results $(URIBASE)/uberon/$@ --add-ontology-annotation $(DC)/description "Life cycle stage subset of uberon composite-vertebrate ontology (includes species stage ontologies)" -o -f obo --no-check $@ --reasoner-dispose 2>&1 > $@.LOG

subsets/life-stages-core.obo: uberon.owl
	owltools $< --reasoner-query -r elk -l 'life cycle stage' --make-ontology-from-results $(URIBASE)/uberon/$@ --add-ontology-annotation $(DC)/description "Life cycle stage subset of uberon core (generic stages only)" -o -f obo $@ --reasoner-dispose 2>&1 > $@.LOG
subsets/life-stages-core.owl: uberon.owl
	owltools $< --reasoner-query -r elk -l 'life cycle stage' --make-ontology-from-results $(URIBASE)/uberon/$@ --add-ontology-annotation $(DC)/description "Life cycle stage subset of uberon core (generic stages only)" -o file://`pwd`/$@ --reasoner-dispose 2>&1 > $@.LOG

subsets/immaterial.obo: merged.owl
	owltools $< --reasoner-query -r elk -d  UBERON_0000466  --make-ontology-from-results $(URIBASE)/uberon/$@ -o -f obo $@ --reasoner-dispose 2>&1 > $@.LOG


subsets/%.owl: subsets/%.obo
	owltools $< -o $@.tmp && mv $@.tmp $@


# ----------------------------------------
# HISTORIC/LEGACY, NEEDS PRESERVED
# ----------------------------------------

# get rid of non subclass xrefs
%-xf.obo: %.obo
	egrep -v '^xref: (OpenCyc|http)' $< > $@

# used for (obsolete) disjointness checks

# historic
#%-with-isa.obo: %-xf.obo
#	blip -i $*.obo -u ontol_manifest_has_subclass_from_xref io-convert -to obo -o $@
#.PRECIOUS: %-with-isa.obo

# for now we use a simplified set of relations, as this is geared towards analysis
#TODO @cmungall
subsets/uberon-with-isa-for-%.obo: uberon.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-ddb -i $< -u ontol_manifest_has_subclass_from_selected_xref -u ontol_management -goal "set_selected_idspaces('$*'),retractall(ontol_db:disjoint_from(_,_)),delete_relation_usage_except([develops_from,part_of,continuous_with,capable_of])" io-convert -to obo -o $@
.PRECIOUS: %-with-isa.obo

uberon-isa-to-%.obo: uberon.obo
	$(SCRIPTSDIR)/obo-grep.pl -r '^id: $*' $< > $@


# @Dep
other-bridges: merged.owl
	owltools $< --extract-bridge-ontologies -d tmp -s uberon -x -o -f obo $(TMPDIR)/minimal.obo

# ----------------------------------------
# CL (to be replaced)
# ----------------------------------------

# core: the full ontology, excluding external classes, but including references to these
# TODO: use --make-subset-by-properties
# note: requires symlink to cl directory
$(TMPDIR)/cl-core.obo: $(SRC)
	owltools $(URIBASE)/cl.owl  --make-subset-by-properties -n BFO:0000050 BFO:0000051 RO:0002202 RO:0002215 --remove-external-classes -k CL --remove-axiom-annotations --remove-imports-declarations -o -f obo --no-check $@
#$(TMPDIR)/cl-core.obo: cell-ontology/cl.obo
#	$(SCRIPTSDIR)/obo-grep.pl -r 'id: CL:' $< | grep -v ^intersection_of | grep -v ^disjoint | grep -v ^equivalent | grep -v ^owl-axioms | (obo-filter-relationships.pl -t part_of -t capable_of -t develops_from - && cat develops_from.obo part_of.obo has_part.obo capable_of.obo)  > $@

# TODO - this may replace the above BUT need to preserve dangling axioms
cl-core-new.obo: cell-ontology/cl.obo
	owltools $< --make-subset-by-properties BFO:0000050 RO:0002202 RO:0002215 // --remove-axioms -t DisjointClasses -o -f obo $@

# this is required for bridging axioms; ZFA inverts the usual directionality
$(TMPDIR)/cl-zfa-xrefs.obo: $(TMPDIR)/zfa.owl
	$(ROBOT) query -i $< --query ../sparql/zfa-xrefs-to-cl.sparql $@_xrefs_to_zfa.tsv
	cat $@_xrefs_to_zfa.tsv | tail -n +2 | $(SCRIPTSDIR)/tbl2obolinks.pl --rel xref - > $@.tmp && mv $@.tmp $@


	#blip-findall -r ZFA "entity_xref(Z,C),id_idspace(C,'CL')" -select C-Z -use_tabs -no_pred | $(SCRIPTSDIR)/tbl2obolinks.pl  --rel xref > $@

#cl-core.owl: $(TMPDIR)/cl-core.obo
#	$(MAKEOBO)
#	#obolib-obo2owl --allow-dangling $< -o $@

# ----------------------------------------
# OBO-BASIC CHECKS
# ----------------------------------------

# NOTE: we should be able to replace these with oort now
#TODO @cmungall
$(REPORTDIR)/%-cycles: %.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	owltools --no-debug $< --list-cycles -f > $@
	#blip-findall -i $< "subclass_cycle/2" -label > $@

$(REPORTDIR)/%-allcycles: %.owl
	owltools --no-debug $< --list-cycles -f > $@

#TODO @cmungall
$(REPORTDIR)/basic-allcycles:
	echo "STRONG WARNING: $@ skipped, because currently failing."
	owltools --no-debug $< --list-cycles -f > $@ || true

# TODO: use ROBOT
#TODO @cmungall
#%-synclash: %.obo
#	blip-findall -u query_obo -i $< "same_label_as(X,Y,A,B,C),X@<Y,class_refcount(X,XC),class_refcount(Y,YC)" -select "same_label_as(X,Y,A,B,C,XC,YC)" -label > $@
$(REPORTDIR)/%-synclash: %.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -u query_obo -i $< "same_label_as(X,Y,A,B,C),X@<Y,class_refcount(X,XC),class_refcount(Y,YC)" -select "same_label_as(X,Y,A,B,C,XC,YC)" -label > $@

# ----------------------------------------
# COMPOSITE STAGES
# ----------------------------------------

$(TMPDIR)/update-stages: $(SRC) | $(TMPDIR)
	rm -rf $(TMPDIR)/developmental-stage-ontologies && \
	cd $(TMPDIR) && \
	git clone https://github.com/obophenotype/developmental-stage-ontologies.git && \
	cd developmental-stage-ontologies/src && make OWLTOOLS=owltools all ssso-merged.obo -B && cd ../../../ && \
	touch $@

CSTAGES := $(filter-out %bridge-to-uberon.obo, $(wildcard $(TMPDIR)/developmental-stage-ontologies/*/*-uberon.obo))
#CSTAGES := $(wildcard $(TMPDIR)/developmental-stage-ontologies/*/*-uberon.obo)

#merged-stages.obo:  $(OWLSRC)
#	owltools $(filter-out %-uberon.obo, $(wildcard $(TMPDIR)/developmental-stage-ontologies/*/*.obo)) -o -f obo $@

# TODO: properly trigger this from changes
# "entity_xref_idspace(X,U,'UBERON')" -no_pred -label -select U-X
# this is a basic xref query, all xrefs TO an uberon ID. The TSV output is col1:UberonID col2:speciesSpecificStageTermID
$(TMPDIR)/merged-stages-xrefs.obo: #$(TMPDIR)/developmental-stage-ontologies/src/ssso-merged.obo | $(TMPDIR)/update-stages blip
	$(ROBOT) query -i $(TMPDIR)/developmental-stage-ontologies/src/ssso-merged.obo --query ../sparql/xrefs-to-uberon.sparql $@_xrefs_to_uberon.tsv 
	cat $@_xrefs_to_uberon.tsv | tail -n +2 | $(SCRIPTSDIR)/tbl2obolinks.pl -k  --rel xref - > $@.tmp && mv $@.tmp $@

$(TMPDIR)/composite-stages.obo: $(TMPDIR)/merged-stages-xrefs.obo #$(TMPDIR)/update-stages
	owltools $(CSTAGES) $(TMPDIR)/merged-stages-xrefs.obo --merge-support-ontologies -o -f obo --no-check $@

# ----------------------------------------
# COMPOSITE ANATOMY: PREPROCESSING
# ----------------------------------------

composites: composite-metazoan.obo composite-vertebrate.obo



# ----------------------------------------
# COMPOSITE ANATOMY: BUILDING
# ----------------------------------------

.PHONY: dependencies
dependencies:
	apt-get install -y libjson-perl

# many external ontologies do not adhere to all uberon constraints
$(TMPDIR)/ext-weak.owl: ext.owl | $(TMPDIR)
	owltools $(UCAT) $< --merge-imports-closure --remove-axioms -t DisjointClasses --remove-equivalent-to-nothing-axioms -o $@

MBASE = $(TMPDIR)/ext-weak.owl $(BRIDGEDIR)/bridges $(TMPDIR)/local-ma.owl $(TMPDIR)/local-ehdaa2.owl $(TMPDIR)/local-emapa.owl $(TMPDIR)/local-xao.owl \
	$(TMPDIR)/local-zfa.owl $(TMPDIR)/local-fbbt.owl $(TMPDIR)/local-fbdv.owl \
	$(TMPDIR)/local-wbbt.owl $(TMPDIR)/local-wbls.owl $(TMPDIR)/local-ceph.owl \
	$(TMPDIR)/local-cteno.owl $(TMPDIR)/local-poro.owl $(TMPDIR)/allen-mba.obo $(TMPDIR)/allen-pba.obo $(TMPDIR)/allen-hba.obo \
	$(TMPDIR)/allen-dmba.obo $(TMPDIR)/allen-dhba.obo uberon.owl \
	dependencies

# A subset of OPs will be turned into taxon GCIs
TAXON_GCI_RELS = RO:0002202 RO:0002496 RO:0002497 BFO:0000051

MERGESPECIES =\
  --merge-species-ontology -s 'mouse' -t NCBITaxon:10090 -q $(TAXON_GCI_RELS) \
  --merge-species-ontology -s 'human' -t NCBITaxon:9606 -q $(TAXON_GCI_RELS) \
  --merge-species-ontology -s 'primate' -t NCBITaxon:9443 \
  --merge-species-ontology -s 'Xenopus' -t NCBITaxon:8353 \
  --merge-species-ontology -s 'Danio' -t NCBITaxon:7954 \
  --merge-species-ontology -s 'Drosophila' -t NCBITaxon:7227 \
  --merge-species-ontology -s 'C elegans' -t NCBITaxon:6237 \

MERGE_EQSETS =  --merge-equivalence-sets -s UBERON 10 -s CL 9 -s CARO 5  -l UBERON 10 -l CL 9 -d UBERON 10 -d CL 9

MAKESPMERGE= $(UCAT)\
  --map-ontology-iri $(URIBASE)/uberon.owl $(TMPDIR)/ext-weak.owl\
  --map-ontology-iri $(URIBASE)/fma.owl $(COMPONENTSDIR)/null.owl\
  --map-ontology-iri $(URIBASE)/uberon/bridge/uberon-bridge-to-fma.owl $(COMPONENTSDIR)/null.owl\
 $(URIBASE)/uberon/$(BRIDGEDIR)/collected-$*.owl --merge-imports-closure

# bundled: collect all ontologies and do a basic (non-species) import closure merge
# primarily for testing: not released
bundled-%.owl: $(MBASE)
	OWLTOOLS_MEMORY=12G owltools $(MAKESPMERGE) --merge-import-closure -o -f ofn $@
.PRECIOUS: $(TMPDIR)/unreasoned-composite-%.owl

# stage1 of composite build: do a species merge, but no additional reasoning
$(TMPDIR)/unreasoned-composite-%.owl: $(MBASE)
	OWLTOOLS_MEMORY=12G owltools $(MAKESPMERGE) --reasoner elk $(MERGESPECIES) $(MERGE_EQSETS) -o -f ofn $@
.PRECIOUS: $(TMPDIR)/unreasoned-composite-%.owl

# stage 2 (final) of composite build: reason
composite-%.owl: $(TMPDIR)/unreasoned-composite-%.owl
	$(ROBOT) reason -r ELK -i $< relax reduce -r ELK -o $@.tmp.owl && mv $@.tmp.owl $@
.PRECIOUS: composite-%.owl

# composute obo is made from owl
composite-%.obo: composite-%.owl
	owltools $< --add-obo-shorthand-to-properties -o -f obo --no-check $@.tmp && grep -v ^owl-axioms: $@.tmp > $@

composite-metazoan.owl: $(TMPDIR)/unreasoned-composite-metazoan.owl
	$(ROBOT) reason -r ELK -i $< relax reduce -r ELK -o $@.tmp.owl && mv $@.tmp.owl $@
.PRECIOUS: composite-%.owl

composite-vertebrate.owl: $(TMPDIR)/unreasoned-composite-vertebrate.owl
	$(ROBOT) reason -r ELK -i $< relax reduce -r ELK -o $@.tmp.owl && mv $@.tmp.owl $@
.PRECIOUS: composite-vertebrate.owl

#TODO is this needed?
composite-metazoan-basic.obo: composite-metazoan.owl
	owltools $<  --extract-mingraph --remove-axiom-annotations --make-subset-by-properties -f $(BASICRELS) --set-ontology-id $(URIBASE)/uberon/composite-metazoan-basic.owl -o -f obo --no-check $@.tmp && mv $@.tmp  $@.tmp2 && grep -v '^owl-axioms:' $@.tmp2 > $@

# ----------------------------------------
# TAXON MODULES
# ----------------------------------------

all_taxmods: $(TAXMODSDIR)/uberon-taxmod-amniote.obo $(TAXMODSDIR)/uberon-taxmod-euarchontoglires.obo
#all_taxmods: uberon-taxmod-amniote.obo uberon-taxmod-aves.obo uberon-taxmod-euarchontoglires.obo

# ELK DOES NOT COMPLETE
#uberon-taxmod-aves.owl: uberon-taxmod-8782.owl
#	cp $< $@

$(TAXMODSDIR)/uberon-taxmod-euarchontoglires.owl: $(TMPDIR)/uberon-taxmod-314146.owl
	cp $< $@
$(TAXMODSDIR)/uberon-taxmod-amniote.owl: $(TMPDIR)/uberon-taxmod-32524.owl
	cp $< $@
$(TAXMODSDIR)/uberon-taxmod-human.owl: $(TMPDIR)/uberon-taxmod-9606.owl
	cp $< $@

#$(TAXMODSDIR)/uberon-taxmod-annelid.owl: $(TMPDIR)/uberon-taxmod-6340.owl
#	cp $< $@


$(TAXMODSDIR)/uberon-taxmod-%.obo: $(TAXMODSDIR)/uberon-taxmod-%.owl
	OWLTOOLS_MEMORY=14G owltools $(UCAT) $< --remove-imports-declarations -o -f obo --no-check $@.tmp && grep -v ^owl $@.tmp > $@

# added --allowEquivalencies, see https://github.com/geneontology/go-ontology/issues/12926
$(TMPDIR)/uberon-taxmod-%.owl: ext.owl
	owltools --use-catalog $< --reasoner elk --make-species-subset -t NCBITaxon:$*  --assert-inferred-subclass-axioms --allowEquivalencies --useIsInferred --remove-dangling --set-ontology-id $(URIBASE)/uberon/subsets/$@ -o $@ 2>&1 > $@.log
#uberon-taxmod-%.owl: uberon-taxmod-%.ids
#	blip-ddb -u ontol_db -r uberonp -format "tbl(ids)" -i $< -goal "forall((class(C),\+ids(C)),delete_class(C)),remove_dangling_facts" io-convert -to obo > $@
#	blip ontol-query -r uberonp -format "tbl(ids)" -i $< -to obo -query "ids(ID)" > $@.tmp && grep -v ^disjoint_from $@.tmp | grep -v 'relationship: spatially_disjoint' > $@
.PRECIOUS: $(TMPDIR)/uberon-taxmod-%.owl


#taxtable.txt: $(SRC)
#	owltools $< --make-class-taxon-matrix --query-taxa external/ncbitaxon-subsets/taxslim.obo -o z NCBITaxon:9606 NCBITaxon:7955


# ----------------------------------------
# BRIDGES
# ----------------------------------------

# seed.owl is never released - it is used to seed module extraction
$(TMPDIR)/seed.owl: $(TMPDIR)/phenoscape-ext-noimports.owl $(OWLSRC) $(TMPDIR)/cl-core.obo
	owltools $(UCAT) $(OWLSRC) $< $(TMPDIR)/cl-core.obo --merge-support-ontologies -o -f functional $@

# this is used for xrefs for bridge files
# TODO: investigate why this necessary: --add-support-from-imports --remove-imports-declarations
$(TMPDIR)/seed.obo: $(TMPDIR)/seed.owl
	owltools $(UCAT) $< --add-support-from-imports --remove-imports-declarations  -o -f obo --no-check $@.tmp && $(SCRIPTSDIR)/obo-grep.pl --neg -r is_obsolete $@.tmp > $@

BRIDGESRC_OBO = $(SRC) $(TMPDIR)/cl-with-xrefs.obo
$(BRIDGEDIR)/uberon-bridge-to-nifstd.obo: $(SRC)
	$(SCRIPTSDIR)/xref-to-equiv.pl uberon/$(BRIDGEDIR)/uberon-bridge-to-nifstd http://uri.neuinfo.org/nif/nifstd/  $< > $@.tmp && mv $@.tmp $@
$(BRIDGEDIR)/%.owl: $(BRIDGEDIR)/%.obo
	owltools --use-catalog $< --remove-annotation-assertions -o $@

make-bridge-ontologies-from-xrefs.pl:
	cp $(SCRIPTSDIR)/make-bridge-ontologies-from-xrefs.pl $@

$(BRIDGEDIR)/bridges: $(BRIDGEDIR)/uberon-bridge-to-vhog.owl $(TMPDIR)/seed.obo $(TMPDIR)/cl-with-xrefs.obo $(BRIDGEDIR)/uberon-bridge-to-nifstd.owl make-bridge-ontologies-from-xrefs.pl
	cd $(BRIDGEDIR) && perl ../make-bridge-ontologies-from-xrefs.pl ../$(TMPDIR)/seed.obo && perl ../make-bridge-ontologies-from-xrefs.pl -b cl ../$(TMPDIR)/cl-with-xrefs.obo ../$(TMPDIR)/cl-zfa-xrefs.obo && touch bridges

$(TMPDIR)/cl-with-xrefs.obo: $(TMPDIR)/cl-core.obo $(SCRIPTSDIR)/expand-idspaces.pl
	egrep '^(idspace|treat-)' $(SRC) > $@ && cat $< >> $@.tmp && $(SCRIPTSDIR)/expand-idspaces.pl $@.tmp > $@

$(BRIDGEDIR)/uberon-bridge-to-vhog.owl: $(SRC) $(SCRIPTSDIR)/mk-vhog-individs.pl
	$(SCRIPTSDIR)/mk-vhog-individs.pl organ_association_vHOG.txt $(SRC) > $@.ofn && owltools $@.ofn -o file://`pwd`/$@

#TODO @cmungall
$(BRIDGEDIR)/uberon-bridge-to-emap.obo: mapping_EMAP_to_EMAPA.txt $(TMPDIR)/update-stages
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-query -r emapa -r emap -consult util/emap_to_cdef.pro -i $< -i uberon.obo -i $(TMPDIR)/developmental-stage-ontologies/src/mmusdv/mmusdv.obo -query "mapping_EMAP_to_EMAPA(ID,_,_)" -to obo | perl -npe 's/OBO_REL://' > $@.tmp && $(SCRIPTSDIR)/emap-to-cdef-add-hdr.pl $@.tmp > $@
.PRECIOUS: $(BRIDGEDIR)/uberon-bridge-to-emap.obo
$(BRIDGEDIR)/uberon-bridge-to-emap.owl: $(BRIDGEDIR)/uberon-bridge-to-emap.obo
	$(MAKEOBO)

$(BRIDGEDIR)/uberon-ext-bridge-to-zfa.obo: $(BRIDGEDIR)/ext-xref.obo make-bridge-ontologies-from-xrefs.pl
	cd bridge && ../make-bridge-ontologies-from-xrefs.pl -b uberon-ext ext-xref.obo

# see #157
#TODO @cmungall
ext-xref-conflict.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r pext -r ZFA -i pe/tao-obsoletions.obo "entity_xref(Z,T),entity_replaced_by(T,U),\+id_idspace(Z,'UBERON'),id_idspace(U,'UBERON'),entity_xref(U,Zx),id_idspace(Zx,'ZFA'),Zx\=Z" -select "x(U,Z,Zx)" -label > $@
#TODO @cmungall
ext-xref-conflict2.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r pext -r ZFA -i pe/tao-obsoletions.obo "entity_xref(Z,T),entity_replaced_by(T,U),\+id_idspace(Z,'UBERON'),id_idspace(U,'UBERON'),entity_xref(Ux,Z),id_idspace(Ux,'UBERON'),Ux\=U" -select "x(U,Z,Ux)" -label > $@

release-diff:
	cd diffs && make

# ----------------------------------------
# RELEASE DEPLOYMENT
# ----------------------------------------
# even tho the repo lives in github, release is via svn...

RELDIR=./trunk

.PHONY: dirs

dirs:
	rm -rf $(RELDIR)
	mkdir -p $(RELDIR)
	mkdir -p $(RELDIR)/subsets
	mkdir -p $(RELDIR)/diffs
	mkdir -p $(RELDIR)/reference
	mkdir -p $(RELDIR)/bridge
	mkdir -p $(RELDIR)/reports


release: dirs
	cp core.owl $(RELDIR)/core.owl ;\
	cp $(SRC) $(RELDIR)/core.obo ;\
	cp uberon.{obo,owl,json} $(RELDIR) ;\
	cp merged.{obo,owl} $(RELDIR)/ ;\
	cp uberon-base.owl $(RELDIR) ;\
	cp basic.{obo,owl,json} $(RELDIR)/ ;\
	cp homology.owl $(RELDIR)/homology.owl ;\
	cp *_import.owl $(RELDIR)/ ;\
	cp $(BRIDGEDIR)/*.{obo,owl} $(RELDIR)/$(BRIDGEDIR)/ ;\
	cp depictions.owl $(RELDIR)/ ;\
	cp ext.{obo,owl,json} $(RELDIR)/ ;\
	cp $(TMPDIR)/external-disjoints.owl $(RELDIR)/ ;\
	cp $(TMPDIR)/external-disjoints.owl $(RELDIR)/$(BRIDGEDIR)/ ;\
	cp components/external-disjoints.obo $(RELDIR)/ ;\
	cp components/external-disjoints.obo $(RELDIR)/$(BRIDGEDIR)/ ;\
	cp subsets/*.{obo,owl} $(RELDIR)/subsets/ ;\
	cp subsets/*-view.{obo,owl} $(RELDIR)/subsets/ ;\
	cp reports/*.tsv $(RELDIR)/reports/ ;\
	cp $(TAXMODSDIR)/uberon-taxmod-amniote.obo $(RELDIR)/subsets/amniote-basic.obo ;\
	cp $(TAXMODSDIR)/uberon-taxmod-amniote.owl $(RELDIR)/subsets/amniote-basic.owl ;\
	cp $(TAXMODSDIR)/uberon-taxmod-euarchontoglires.obo $(RELDIR)/subsets/euarchontoglires-basic.obo ;\
	cp $(TAXMODSDIR)/uberon-taxmod-euarchontoglires.owl $(RELDIR)/subsets/euarchontoglires-basic.owl ;\
	cp composite-brain.{obo,owl} $(RELDIR) ;\
	cp composite-{vertebrate,metazoan}.{obo,owl} $(RELDIR) ;\
	cp composite-{vertebrate,metazoan}-*.{obo,owl} $(RELDIR) ;\
	cp reference/*.{owl,md} $(RELDIR)/reference  ;\
	make release-diff ;\
	cp diffs/* $(RELDIR)/diffs/ ;\
	echo done ;\
#	cd $(RELDIR) && svn commit -m ''

S3CMD = s3cmd -c ~/.s3cfg.go-push --acl-public --reduced-redundancy 

# see https://github.com/obophenotype/uberon/issues/1551
# we now use S3 directly

deploy: deploy-main deploy-top

deploy-main:
	$(S3CMD) sync $(RELDIR)/ s3://bbop-ontologies/uberon/
deploy-top:
	$(S3CMD) sync $(RELDIR)/uberon.{obo,owl,json} s3://bbop-ontologies/



# ----------------------------------------
# RELEASE
# ----------------------------------------
aao.obo:
	wget $(URIBASE)/aao.obo

fbbt.obo:
	wget $(URIBASE)/fbbt.obo

# See: http://code.google.com/p/caro2/issues/detail?id=10
$(BRIDGEDIR)/fbbt-nd.obo: fbbt.obo
	grep -v ^disjoint $< | perl -npe 's@^ontology: fbbt@ontology: uberon/fbbt-nd@' > $@.tmp && owltools --use-catalog $@.tmp -o -f obo $@

#TODO @cmungall
$(BRIDGEDIR)/caro-bridge-to-zfa.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r uberonp -consult util/caro_equiv.pro "ec(C,Z,'ZFA')" -select C-Z  -no_pred | $(SCRIPTSDIR)/tbl2obolinks.pl --rel equivalent_to - > $@

#TODO @cmungall
$(BRIDGEDIR)/caro-bridge-to-xao.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r uberonp -consult util/caro_equiv.pro "ec(C,Z,'XAO')" -select C-Z  -no_pred | $(SCRIPTSDIR)/tbl2obolinks.pl --rel equivalent_to - > $@



# ///////////////////////
# ///////////////////////
# ///  odds and ends ////
# ///////////////////////
# ///////////////////////

# ----------------------------------------
# OTHER
# ----------------------------------------

#TODO @cmungall
xrefs/uberon-to-umls.tbl: uberon.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r NCITA  -i $< "entity_xref(U,X),inst_sv(X,'\"UMLS_CUI\"',C,_)" -select U-C -no_pred -label -use_tabs > $@.tmp && mv $@.tmp $@

#TODO @cmungall
xrefs/uberon-to-umls.obo: uberon.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r NCITA  -i $< "entity_xref(U,X),inst_sv(X,'\"UMLS_CUI\"',C,_),atom_concat('UMLS:',C,CX)" -select U-CX -no_pred -use_tabs | $(SCRIPTSDIR)/tbl2obolinks.pl --rel xref  > $@.tmp && mv $@.tmp $@

#TODO @cmungall
xrefs/uberon-to-umls-merged.obo: xrefs/uberon-to-umls.obo
	obo-merge-tags.pl -t xref $(SRC) $< > $@ && diff -u $@ $(SRC) || echo



# OBO-Format Hacking
%-cmt.obo: %.obo
	obo-add-comments.pl -t xref -t intersection_of $(SRC) animal_gross_anatomy/*/*.obo ../cell_type/cell.obo ../caro/caro.obo MIAA.obo animal_gross_anatomy/*/*/*.obo ~/cvs/fma-conversion/fma2/fma2.obo gemina_anatomy.obo birnlex_anatomy.obo NIF-GrossAnatomy.obo hao.obo HOG.obo efo_anat.obo $< > $@

caloha.obo:
	wget ftp://ftp.nextprot.org/pub/current_release/controlled_vocabularies/caloha.obo -O $@


xcaloha.obo: caloha.obo
	perl -npe 's/TS\-/CALOHA:TS\-/g' $< > $@

# KIl all the following
#uberon-new-mp.obo:
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	blip -u query_anatomy -i $(SRC) -r cell  -r EMAPA -r mammalian_phenotype -r mammalian_phenotype_xp  -r fma_downcase -r NIFGA -r zebrafish_anatomy  -r mouse_anatomy findall uberon_mpxp_write > $@

#uberon-new-hp.obo:
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	#blip -u query_anatomy -i $(SRC) -r cell -r human_phenotype -r human_phenotype_xp -r NIFGA -r zebrafish_anatomy -r mouse_anatomy -r EMAPA -goal "uberon_mpxp_write,halt" > $@

#uberon-new-go.obo:
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	#blip -u query_anatomy -i $(SRC) -r cell -r go -r goxp/biological_process_xp_uber_anatomy -r NIFGA -r zebrafish_anatomy -r mouse_anatomy -r EMAPA -r goxp/biological_process_xp_fly_anatomy -r goxp/biological_process_xp_plant_anatomy -r goxp/biological_process_xp_zebrafish_anatomy -goal "uberon_goxp_write,halt" > $@

#cl-new-go.obo:
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	#blip -u query_anatomy -i $(SRC) -r cell -r go -r goxp/biological_process_xp_uber_anatomy -r goxp/biological_process_xp_cell  -r zebrafish_anatomy -r mouse_anatomy -r EMAPA -r goxp/biological_process_xp_fly_anatomy -r goxp/biological_process_xp_plant_anatomy -r goxp/biological_process_xp_zebrafish_anatomy -goal "cl_goxp_write,halt" > $@

#uberon-defs-from-mp.obo:
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	#blip -u query_anatomy -i $(SRC) -r mammalian_phenotype  -goal "uberon_mpxp_write_defs,halt" > $@

#%.xrefcount: %.obo
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -i $< -u ontol_db findall -label '(class(C),setof_count(X,class_xref(C,X),Num))' -select 'C-Num' | sort -k3 -n > $@

#caloha-not-in-uberon.txt:
#	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
#	#blip-findall -consult util/ubxref.pro -i uberon.obo -r caloha "class(X),atom_concat('TS-',_,X),\+ubxref(_,X)" -select X -label

# kill till here

# ----------------------------------------
# Neurolex
# ----------------------------------------
nlx-%.owl: $(TMPDIR)/nlx_stage_all.rdf 
	owltools --catalog-xml catalog-nlx.xml $< --abox-to-tbox  --reasoner-query -r elk -d  -l "$*" -c $(URIBASE)/nlx/neuron  -o $@
#	owltools --catalog-xml catalog-nlx.xml $<  --reasoner-query -r elk -d -l "$*" --abox-to-tbox  --make-ontology-from-results $(URIBASE)/nlx/neuron.owl -o $@

# ----------------------------------------
# Rules
# ----------------------------------------
#TODO @cmungall
ipo.obo: uberon.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall  -i $< -consult util/partof.pro new_part_of/2 -label -no_pred -use_tabs | sort -u | $(SCRIPTSDIR)/tbl2obolinks.pl  --rel part_of --source reference_0000032 - > $@

# ----------------------------------------
# REPORTING
# ----------------------------------------

# DOCS
#TODO @cmungall
relation_table.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r uberon -consult util/relation_report.pro "row(R)" -select R > relation_table.txt

#TODO @cmungall
%-relstats: %.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r uberon  "aggregate(count,X-T,parent(X,R,T),Num)" -select "R-Num" -no_pred | | sort -nk2 > $@

#TODO @cmungall
%-el.owl: %.owl
	makeElWithoutReasoning.sh -i `pwd`/$< -o `pwd`/$@

# ----------------------------------------
# SPELLCHECK
# ----------------------------------------

# notes:
# to add to a dict
# yes a | aspell check --home-dir . obo-syntax.html
#
# setting --home-dir to . will cause the dictionary .aspell.en.pws  in this directory to be used

# interactive
ispellcheck: $(SRC)-ispellcheck

# batch
spellcheck: $(SRC)-spellcheck

%-spellcheck: %
	cat $< | aspell -a check --home-dir . 

%-ispellcheck: %
	aspell check --home-dir . $<

# ----------------------------------------
# wikipedia
# ----------------------------------------

#TODO @cmungall
%-wikipedia.xrefs: %.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#(blip -i $< -u web_fetch_wikipedia -u query_anatomy findall class_wikipage/2 > $@) 2>&1 > $@.err

%-wikipedia.pro: %-wikipedia.xrefs
	./wikitbl2defxref.pl $< | tbl2p > $@

%-wikipedia.merge: %-wikipedia.xrefs
	./wikitbl2defxref.pl $< | cut -f2,3 | $(SCRIPTSDIR)/tbl2obolinks.pl --rel xref > $@

#nif_anatomy.obo:
#	blip -i http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.owl -f thea2_owl -import_all io-convert -to obo -u ontol_manifest_metadata_from_nif_via_thea -o $@.tmp && ./downcase-obo.pl $@.tmp > $@

#TODO @cmungall
nif_subcellular.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -i http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-Subcellular.owl -f thea2_owl -import_all io-convert -to obo -u ontol_manifest_metadata_from_nif_via_thea -o $@.tmp && ./nif-downcase-obo.pl $@.tmp > $@

#TODO @cmungall
nif_cell.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -i http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-Cell.owl -f thea2_owl -import_all io-convert -to obo -u ontol_manifest_metadata_from_nif_via_thea -o $@.tmp && ./nif-downcase-obo.pl $@.tmp > $@

# VHOG
organ_association.txt:
	wget http://bgee.unil.ch/download/organ_association.txt

stages.obo:
	wget http://bgee.unil.ch/download/stages.obo

#mapping_EMAP_to_EMAPA.txt:
#	wget ftp://lausanne.isb-sib.ch/pub/databases/Bgee/general/mapping_EMAP_to_EMAPA.txt
mapping_EMAP_to_EMAPA.txt:
	wget ftp://ftp.hgu.mrc.ac.uk/pub/MouseAtlas/Anatomy/EMAP-EMAPA.txt -O $@

# e.g. raw_similarity_annotations.tsv
ASA=raw_similarity_annotations
asa-%.tsv:
	wget --no-check-certificate https://raw.githubusercontent.com/BgeeDB/anatomical-similarity-annotations/master/release/$*.tsv -O $@
#	cp $(HOME)/repos/cmungall/anatomical-similarity-annotations/release/$@ $@
#       ^^^ use this when forking is required

homology.jsonld: asa-$(ASA).tsv $(SCRIPTSDIR)/sim2jsonld.pl
	$(SCRIPTSDIR)/sim2jsonld.pl $< > $@

homology.ttl: homology.jsonld
	riot -q $< > $@


homology.owl: homology.ttl homology-relations.owl
	owltools --use-catalog $^ --merge-support-ontologies -o $@

simil%.pro: simil%.tsv
	$(SCRIPTSDIR)/sim2pro.pl $< | tbl2p > $@.tmp && mv $@.tmp $@


# ----------------------------------------
# VIEWS
# ----------------------------------------
%-partview.owl: %.owl
	owltools $< --remove-subset grouping_class --remove-subset upper_level --bpvo --reflexive --prefix "" --suffix " part" -r elk -p BFO:0000050 --replace --set-ontology-id $(URIBASE)/uberon/$@ -o -f ttl $@
##	owltools $< --bpvo --prefix "" --suffix " part" -r elk -p BFO:0000050 --set-ontology-id $(URIBASE)/uberon/$@ -o $@

%-exprview.owl: %.owl
	owltools --use-catalog $< $(URIBASE)/ro.owl --merge-support-ontologies  --remove-subset grouping_class --remove-subset upper_level --bpvo  --prefix " expressed in" --suffix "" -r elk -p BFO:0000050 --replace --set-ontology-id $(URIBASE)/uberon/$@ -o -f ttl $@

%-homolview.owl: %.owl
	owltools --use-catalog $< $(URIBASE)/ro.owl homologous-to-part-of.obo --merge-support-ontologies  --remove-subset grouping_class --remove-subset upper_level --bpvo  --prefix " expressed in" --suffix "" -r elk -p UBREL:0002000 --replace --set-ontology-id $(URIBASE)/uberon/$@ -o -f ttl $@


# ----------------------------------------
# TEXT MINING
# ----------------------------------------

#%-matches.tbl: %.txt
#	 blip-findall  -debug index -index "metadata_nlp:entity_label_token_list_stemmed(1,0,0,0)" -u metadata_nlp -i $< -r cell -r uberon "$*(X),label_full_parse(X,true,S)" -select "m(X,S)" -label > $@

# ----------------------------------------
# DBPEDIA
# ----------------------------------------

# note that dbpedia vastly underclassifies here.
# 4k limit seems unusual...
#TODO @cmungall
dbpedia_all_AnatomicalStructure.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	# blip -debug sparql ontol-sparql-remote "SELECT * WHERE {  ?x rdf:type <http://dbpedia.org/ontology/AnatomicalStructure> }" -write_prolog > $@.tmp && sort -u $@.tmp > $@

# this should be subsumed by AnatomicalStructure
dbpedia_all_Embryology.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#ßblip ontol-sparql-remote "SELECT * WHERE {  ?x rdf:type <http://dbpedia.org/ontology/Embryology> }" -write_prolog > $@.tmp && sort -u $@.tmp > $@

dbpedia_all_Animal_anatomy.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE {  ?x <http://purl.org/dc/terms/subject> <http://dbpedia.org/resource/Category:Animal_anatomy> }" -write_prolog > $@.tmp && sort -u $@.tmp > $@

dbpedia_all_Mammal_anatomy.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE {  ?x <http://purl.org/dc/terms/subject> <http://dbpedia.org/resource/Category:Mammal_anatomy> }" -write_prolog > $@.tmp && sort -u $@.tmp > $@

dbpedia_category_%.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE {  ?x <http://purl.org/dc/terms/subject> <http://dbpedia.org/resource/Category:$*> }" -write_prolog > $@.tmp && sort -u $@.tmp > $@
.PRECIOUS: dbpedia_category_%.pro

dbpedia_type_%.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE {  ?x rdf:type dbpedia-owl:$* }" -write_prolog > $@.tmp && sort -u $@.tmp > $@

dbpedia_TH.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT ?x,?y WHERE {  ?x <http://dbpedia.org/property/code> ?y . FILTER strStarts(str(?y),'TH H')  }" -write_prolog > $@.tmp && sort -u $@.tmp > $@


dbpedia_all_Bone.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE {  ?x rdf:type dbpedia-owl:Bone }" -write_prolog > $@.tmp && sort -u $@.tmp > $@
dbpedia_all_Nerve.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE {  ?x rdf:type dbpedia-owl:Nerve }" -write_prolog > $@.tmp && sort -u $@.tmp > $@

dbpedia_subjects.pro:
	sort -u dbpedia_all_*.pro > $@

triples-%.pro: %.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -debug sparql -i $< -u sparql_util "row(A),dbpedia_query_links(A,row(S,P,O),1000,[])" -select "rdf(S,P,O)" -write_prolog > $@
#	blip-findall -debug sparql -i $< -u sparql_util "row(A),dbpedia_query_links(A,row(S,P,O),1000,[sameAs('http://dbpedia.org/property/redirect')])" -select "rdf(S,P,O)" -write_prolog > $@
.PRECIOUS: triples-%.pro

dbpo-%.obo: triples-%.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -i $< -u ontol_bridge_from_dbpedia io-convert -to obo > $@


# everything as type AnatomicalStructure
dbpedia_all.pro: dbpedia_subjects.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -debug sparql -i $< -u sparql_util "row(A),dbpedia_query_links(A,row(S,P,O),1000,[])" -select "rdf(S,P,O)" -write_prolog > $@
dbpedia_all-after-%.pro: dbpedia_all_AnatomicalStructure.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -debug sparql -i $< -u sparql_util "row(A),A@>'http://dbpedia.org/resource/$*',dbpedia_query_links(A,row(S,P,O),1000,[])" -select "rdf(S,P,O)" -write_prolog > $@

# everything with a def_xref to wikipedia
dbpedia_rest.pro: dbpedia_all_AnatomicalStructure.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i adhoc_uberon.pro -r uberon -i $< -u sparql_util "def_xref(C,X),wpxref_url(X,_,A),\+row(A),dbpedia_query_links(A,row(S,P,O),1000,[])" -select "rdf(S,P,O)" -write_prolog > $@

dbpedia_ontol.obo: dbpedia_all.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -i $< -u ontol_bridge_from_dbpedia io-convert -to obo > $@

uberon-thumbnail-xrefs.obo: dbpedia_all.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r uberonp -i dbpedia_all.pro -i adhoc_uberon.pro uberon_thumbnail/2 -label | cut -f2,3 | $(SCRIPTSDIR)/tbl2obolinks.pl --rel xref > $@

# MUSCLES
dbpedia-muscles: dbpedia-muscle-origin-x.obo dbpedia-muscle-insertion-x.obo dbpedia-muscle-nerve-x.obo  dbpedia-muscle-action-x.obo dbpedia-muscle-antagonist-x.obo dbpedia-muscle-agonist-x.obo
dbpedia-muscle-%.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE { ?x dbpprop:$* ?y. ?x rdf:type dbpedia-owl:Muscle}" -write_prolog > $@.tmp && mv $@.tmp $@
.PRECIOUS: dbpedia-muscle-%.pro

dbpedia-muscle-%-x.obo: dbpedia-muscle-%.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -debug match -consult util/dbpedia_to_link.pro -r uberon -i $< "wfact($*)" > $@.tmp && mv $@.tmp $@

dbpedia-t-muscle-%.pro: dbpedia-muscle-%.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i $< "row(A,B)" -select "row(A,'$*',B)" -write_prolog > $@

dbpedia-ALL-muscle.pro: dbpedia-t-muscle-origin.pro dbpedia-t-muscle-insertion.pro dbpedia-t-muscle-nerve.pro  dbpedia-t-muscle-action.pro dbpedia-t-muscle-antagonist.pro 
	cat dbpedia-t-muscle-*.pro > $@

dbpedia-muscle-nlp.obo: dbpedia-ALL-muscle.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -debug match -consult util/dbpedia_to_link.pro -r uberon -u annotator -i $< "initialize_annotator,wfact_nlp" > $@.tmp && mv $@.tmp $@


dbpredia-props: dbpedia-prop-articulations-x.obo

dbpedia-prop-%.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE { ?x dbpprop:$* ?y}" -write_prolog > $@.tmp && mv $@.tmp $@
.PRECIOUS: dbpedia-prop-%.pro

dbpedia-prop-%-x.obo: dbpedia-prop-%.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -debug match -consult util/dbpedia_to_link.pro -r uberon -i $< "wfact($*)" > $@.tmp && mv $@.tmp $@

dbpedia-latin.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE { ?x dbpprop:latin ?y. ?x rdf:type dbpedia-owl:AnatomicalStructure}" -write_prolog > $@.tmp && mv $@.tmp $@

dbpedia-depiction.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE { ?x foaf:depiction ?y. ?x rdf:type dbpedia-owl:AnatomicalStructure}" -write_prolog > $@.tmp && mv $@.tmp $@

dbpedia-redirects.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE { ?y dbpedia-owl:wikiPageRedirects ?x. ?x rdf:type dbpedia-owl:AnatomicalStructure}" -write_prolog > $@.tmp && mv $@.tmp $@
dbpedia-disambig.pro:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-sparql-remote "SELECT * WHERE { ?y dbpedia-owl:wikiPageDisambiguates ?x. ?x rdf:type dbpedia-owl:AnatomicalStructure}" -write_prolog > $@.tmp && mv $@.tmp $@

dbpedia-list-AS.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip -debug sparql ontol-sparql-remote "SELECT * WHERE { ?x rdf:type dbpedia-owl:AnatomicalStructure}" > $@.tmp && mv $@.tmp $@

# then do obo-add-defs.pl defs.txt $(SRC)
defs.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i dbpedia_all.pro -r uberon -i adhoc_uberon.pro "class_newdef(C,D)" | cut -f2,3 > $@

syns.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -index "metadata_nlp:entity_label_token_stemmed(1,0,1,0)" -i dbpedia_all.pro -r uberon -i adhoc_uberon.pro "dbpedia_syn(C,S),class(C,N)" -select "s(C,N,S)" > $@

df.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i dbpedia_all.pro -r uberon -i adhoc_uberon.pro "dbpedia_devfrom(Post,Pre)" -select Post-Pre | cut -f2,3 > $@

new.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i dbpedia_all.pro -r uberon -i adhoc_uberon.pro "dbpedia_new(C)" -select C > $@

ma2ncitx.obo: ma2ncit.obo
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r MA -i $<  -r NCITA "class_xref(M,MX),atom_concat('ncithesaurus:',X,MX),inst_sv(C,_P,X,_)" -select "M-C" -no_pred -label -use_tabs | sort -u | $(SCRIPTSDIR)/tbl2obolinks.pl --rel xref - > $@

# ----------------------------------------
# BTO
# ----------------------------------------
bto-anat.obo:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip ontol-query -r brenda -index "ontol_db:parentT(1,-,1)" -query "parentT(ID,'BTO:0000042'),\+((class(X,N),atom_concat(_,'cell line',N),parentT(ID,X)))" -to obo  > $@

# ----------------------------------------
# ABA
# ----------------------------------------

ALLENS = dmba hba dhba pba mba


#TODO @cmungall has been removed!! especially bridges/aba.owl
#aba.obo: ABA-src.obo
#	$(SCRIPTSDIR)/make-aba-part-ofs.pl $< > $@
#$(BRIDGEDIR)/aba.owl: aba.obo
#	owltools $< -o file://`pwd`/$@

allen_all: $(patsubst %,$(TMPDIR)/allen-%.obo,$(ALLENS))
$(TMPDIR)/allen-dmba.json: | $(TMPDIR)
	wget http://api.brain-map.org/api/v2/structure_graph_download/17.json -O $@
$(TMPDIR)/allen-hba.json: | $(TMPDIR)
	wget http://api.brain-map.org/api/v2/structure_graph_download/10.json -O $@
$(TMPDIR)/allen-dhba.json: | $(TMPDIR)
	wget http://api.brain-map.org/api/v2/structure_graph_download/16.json -O $@
$(TMPDIR)/allen-pba.json: | $(TMPDIR)
	wget http://api.brain-map.org/api/v2/structure_graph_download/8.json -O $@
$(TMPDIR)/allen-mba.json: | $(TMPDIR)
	wget http://api.brain-map.org/api/v2/structure_graph_download/1.json -O $@

$(TMPDIR)/allen-%.obo: $(TMPDIR)/allen-%.json $(SCRIPTSDIR)/allen-json2obo.pl | dependencies
	$(SCRIPTSDIR)/allen-json2obo.pl $< > $@

UNSATS=--term DHBA:146035008 --term DHBA:146035004 --term DHBA:146035012
$(TMPDIR)/allen-dhba.obo: $(TMPDIR)/allen-dhba.json $(SCRIPTSDIR)/allen-json2obo.pl .FORCE | dependencies
	$(SCRIPTSDIR)/allen-json2obo.pl $< > $@
	$(ROBOT) remove -i $@ --prefix "DHBA: http://purl.obolibrary.org/obo/DHBA_" $(UNSATS) --axioms logical -o $@.tmp.obo && mv $@.tmp.obo $@

#TODO @cmungall commented out needs discussion
#$(TMPDIR)/external-brain.obo: $(patsubst %,$(TMPDIR)/allen-%.obo, $(ALLENS)) aba.obo $(TMPDIR)/nlx-ns-part-dn.obo
#	owltools $^ --merge-support-ontologies -o -f obo --no-check $@

# ----------------------------------------
# NIF
# ----------------------------------------
NIF = 
$(TMPDIR)/NIF-GrossAnatomy-src.owl:
	wget http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.owl -O $@
$(TMPDIR)/NIF-GrossAnatomy.owl: $(TMPDIR)/NIF-GrossAnatomy-src.owl
	perl -npe 's@http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.owl#@http://purl.obolibrary.org/obo/NIF_GrossAnatomy_@g' $< > $@
#	perl -npe 's@http://ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.owl#@http://purl.obolibrary.org/obo/NIF_GrossAnatomy:@g' $< > $@

$(TMPDIR)/NIF-GrossAnatomy-orig.obo: $(TMPDIR)/NIF-GrossAnatomy.owl
	owltools $< -o -f obo $@
$(TMPDIR)/NIF-GrossAnatomy.obo: $(TMPDIR)/NIF-GrossAnatomy-orig.obo
	$(SCRIPTSDIR)/fix-nif-ga.pl $< > $@

uberon-nif-combined.owl: uberon.owl
	owltools $< $(BRIDGEDIR)/uberon-bridge-to-nif_grossanatomy.owl $(TMPDIR)/NIF-GrossAnatomy.owl --merge-support-ontologies -o $@

#uberon-nif-combined.obo: uberon.obo
#	obo-cat.pl uberon.obo $(BRIDGEDIR)/uberon-bridge-to-nif_grossanatomy.obo ~/cvs/pkb-owl/ontology.neuinfo.org/NIF/BiomaterialEntities/NIF-GrossAnatomy.obo > $@

uberon-nif-merged.owl: uberon-nif-combined.obo
	owltools $< --reasoner elk  --merge-equivalent-classes -f  -t UBERON -o $@.tmp && grep -v '<oboInOwl:id' $@.tmp > $@
#	owltools $< --reasoner elk --remove-axioms -t DisjointClasses --merge-equivalent-classes -a  -t UBERON -o $@.tmp && grep -v '<oboInOwl:id' $@.tmp > $@

uberon-nif-merged.obo:  uberon-nif-merged.owl
	owltools $< -o -f obo --no-check $@


# ----------------------------------------
# UTIL
# ----------------------------------------
#TODO @cmungall
util/ubermacros.el:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r ro -r go -r pato  -r pext -r mondo -r taxslim -r mondo_edit -consult util/write_ubermacros.pro  w > $@.tmp && sort -u $@.tmp > $@

%-noext.obo: %.obo
	$(SCRIPTSDIR)/obo-grep.pl -r 'id: UBERON:' $< > $@.tmp && mv $@.tmp $@

%-names.txt: %.obo
	grep ^name: $< | grep -v obsolete | perl -npe 's@name: @@' > $@.tmp && sort -u $@.tmp > $@

# ----------------------------------------
# DEAD SIMPLE DESIGN PATTERNS
# ----------------------------------------
MODDIR=modules
#PATTERNDIR=patterns

MODS = luminal_space_of gland_duct gland_acinus endochondral_bone endochondral_cartilage

# OWL->CSV
ONT=uberon
ONTBASE = $(URIBASE)/$(ONT)
PSRC = $(SRC)


# NEW: reverse engineer using patternizer
patternizer:
	pl2sparql   -e -c patterns/patternizer_conf.pl -A void.ttl -i ext doall

# reverse engineer CSV from uberon axioms and DOSDPs
#TODO @cmungall
modules/%.csv: $(PSRC)
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i $< -r pext  -u odputil -i $(PATTERNDIR)/uberon_patterns.pro "write_tuple($*)" > $@.tmp && mv $@.tmp $@
.PRECIOUS: modules/%.csv

modules/new-%.csv: $(PSRC)
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i $< -r pext  -u odputil -i $(PATTERNDIR)/uberon_patterns.pro "write_tuple($*)" > $@.tmp && mv $@.tmp $@
.PRECIOUS: modules/%.csv

# currently, the pattern source is prolog - generate dosdp yaml from this
$(PATTERNDIR)/%.yaml: patterns/uberon_patterns.pro
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -r uberonp  -u odputil -i $(PATTERNDIR)/uberon_patterns.pro "write_yaml($*),fail" > $@.tmp && mv $@.tmp $@
.PRECIOUS: $(PATTERNDIR)/%.yaml

# compare ldef with lexical aspect
modules/conflict_analysis.tsv:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i $(SRC) -r pext  -u odputil -i patterns/uberon_patterns.pro conflicting_tuple_from_ldef/4 -label -no_pred -use_tabs > $@.tmp && mv $@.tmp $@

# some patterns are paired: check for missing members of pairs
modules/missing.txt:
	echo "STRONG WARNING: $@ skipped, because there is no more blip." && touch $@
	#blip-findall -i $(SRC) -r pext -u odputil -i $(PATTERNDIR)/uberon_patterns.pro "nomatch/3" -label -no_pred > $@



all_modules: all_modules_omn all_modules_owl all_modules_obo all_modules_new
all_modules_owl: $(patsubst %, $(MODDIR)/%.owl, $(MODS))
all_modules_omn: $(patsubst %, $(MODDIR)/%.omn, $(MODS))
all_modules_obo: $(patsubst %, $(MODDIR)/%.obo, $(MODS))
all_modules_new: $(patsubst %, $(MODDIR)/%-new.obo, $(MODS))

$(MODDIR)/%.omn: $(MODDIR)/%.csv $(PATTERNDIR)/%.yaml
	apply-pattern.py -s label -P curie_map.yaml -b http://purl.obolibrary.org/obo/ -i $< -p $(PATTERNDIR)/$*.yaml -G $(MODDIR)/$*-gci.owl > $@.tmp && mv $@.tmp $@

#$(MODDIR)/%-gci.owl: $(MODDIR)/%.omn

# need to go via RDF due to OWLAPI bug
$(MODDIR)/%.rdf: $(MODDIR)/%.omn $(MODDIR)/%-gci.owl 
	owltools $^ --merge-support-ontologies --set-ontology-id $(URIBASE)/uberon/$@ -o  $@

$(MODDIR)/%.owl: $(MODDIR)/%.rdf
	owltools $< -o -f ofn $@

$(MODDIR)/%.obo: $(MODDIR)/%.owl
	owltools $< -o -f obo $@.tmp && grep -v ^owl-axioms $@.tmp > $@

$(MODDIR)/%-new.obo: $(MODDIR)/%.owl $(OWLSRC)
	owltools --use-catalog $^ --diff -f obo -s -u  --o1r $@ --o2r $(MODDIR)/%-missing.obo

# ----------------------------------------
# SPARQL
# ----------------------------------------
reports/%.csv: ../sparql/%.sparql uberon.owl
	$(ROBOT) merge -i $< query -s $< $@ -f csv

# ----------------------------------------
# BLAZEGRAPH
# ----------------------------------------

#############################################
############ Nico hacks #####################

$(TMPDIR)/external-disjoints.owl: components/external-disjoints.obo
	$(ROBOT) convert -i $< -f owl -o $@

$(BRIDGEDIR)/uberon-bridge-to-nifstd.obo:
	echo "STRONG WARNING make $@ failed, because xref-to-equiv.pl script is missing!" && touch $@

TEMPLATESDIR=templates

TEMPLATES=$(patsubst %.tsv, $(TEMPLATESDIR)/%.owl, $(notdir $(wildcard $(TEMPLATESDIR)/*.tsv)))

.PHONY: templates
templates: $(TEMPLATES)

$(TEMPLATESDIR)/%.owl: $(TEMPLATESDIR)/%.tsv $(SRC)
	$(ROBOT) -vvv merge -i $(SRC) template --template $< --prefix "EFO: http://www.ebi.ac.uk/efo/EFO_" --output $@ && \
	$(ROBOT) -vvv annotate --input $@ --ontology-iri $(ONTBASE)/components/$*.owl -o $@


$(TMPDIR)/$(ONT)-quick.obo: | dirs
	$(ROBOT) merge -i $(SRC) reason -o $@.owl && mv $@.owl $@

$(TMPDIR)/$(ONT)-main.obo: | dirs
	git show master:$(SRC) > $@
	$(ROBOT) merge -i $@ reason -o $@.owl && mv $@.owl $@

reports/robot_main_diff.md: $(TMPDIR)/$(ONT)-quick.obo $(TMPDIR)/$(ONT)-main.obo
	$(ROBOT) diff --left $(TMPDIR)/$(ONT)-main.obo --right $(TMPDIR)/$(ONT)-quick.obo -f markdown -o $@

.PHONY: feature_diff
feature_diff: reports/robot_main_diff.md
	
	
########################
#### Utility commands ##

.PHONY: bless-mirrors
bless-mirrors:
	touch go.owl chebi.owl mirror/ncbitaxon.obo

.PHONY: quick-qc
quick-qc: core.owl $(REPORTDIR)/uberon-edit-obscheck.txt
	cat $(REPORTDIR)/uberon-edit-obscheck.txt

.PHONY: roundtrip_obo
roundtrip_obo: $(SRC)
	$(ROBOT) convert -i $< -o $(TMPDIR)/roundtrip.obo.tmp.obo && mv $(TMPDIR)/roundtrip.obo.tmp.obo $(TMPDIR)/roundtrip.obo && diff -i $< $(TMPDIR)/roundtrip.obo

.PHONY: normalize
normalize: $(TMPDIR)/NORMALIZE.obo
	mv $< $(SRC)
	echo "$(SRC) has been overwritten! Please carefully check your diff before you commit!"

clean:
	rm -rf ./*.tmp
	rm -rf ./*.tmp1
	rm -rf ./*.tmp2


#uberon_edit-xp-check basic-allcycles uberon_edit-obscheck.txt:
#	echo "skipping $@"

unsat: $(TMPDIR)/bundled-metazoan.owl_unsat.ofn $(TMPDIR)/cl_mondo_merged.owl_unsat.ofn
	
$(TMPDIR)/%_unsat.ofn: %
	$(ROBOT) merge --input $< explain --reasoner ELK \
  -M unsatisfiability --unsatisfiable random:3 --explanation $@.md \
    annotate --ontology-iri "$(ONTBASE)/$@" \
    --output $@
		
cl_mondo_merged.owl:
	$(ROBOT) merge -i uberon.owl -I $(OBO)/cl.owl -o $@