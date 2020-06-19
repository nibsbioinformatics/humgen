#!/usr/bin/env nextflow
/*
========================================================================================
                         nibscbioinformatics/humgen
========================================================================================
 nibscbioinformatics/humgen Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nibscbioinformatics/humgen
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nibscbioinformatics/humgen --input /your/reads/folder -profile singularity

    Mandatory arguments:
      --input [file]                  A folder containing read pairs R1 and R2 for at least one sample ending with .fastq.gz

      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Optional arguments:
      --genome [genome ID]            A genome reference given in the config file humanref.config
                                      Currently defaults to only available option hg19
      --adapter [adapter file]        A FASTA file for the adapter sequences to be trimmed

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}
// Show help message
if (params.help) {
    helpMessage()
    exit 0
}


/*
 * SET UP CONFIGURATION VARIABLES
 */
// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}
// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)


/* ##############################################################
 * Create channels for input reference files and input data files
 * ##############################################################
 */
 // Use an approach like:
 // ch_nucleotide_db = params.nucletide_db ? Channel.value(file(params.nucletide_db)) : "null";

//input channel of (sampleprefix, forward, reverse)
 Channel
     .fromFilePairs("$params.input/*_{R1,R2}*.fastq.gz")
     .ifEmpty { error "Cannot find any reads matching ${params.input}"}
     .set { readpairs }
(ch_read_files_fastqc, inputSample) = readpairs.into(2)

params.genome = "hg19" //this is the default and at the moment the only with all the reference files
params.adapter = "/usr/share/sequencing/references/adapters/TruSeq-adapters-recommended.fa" //change this based on the adapter to trim
ch_adapter = Channel.value(file(params.adapter, checkIfExists: true))

if (params.human_reference && params.genome && !params.human_reference.containsKey(params.genome)) {
   exit 1, "The provided genome '${params.genome}' is not available in the humanref.config file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}
params.dbsnp = params.genome ? params.human_reference[params.genome].dbsnp ?: null : null
if (params.dbsnp) { ch_dbsnp = Channel.value(file(params.dbsnp, checkIfExists: true)) }

params.goldindels = params.genome ? params.human_reference[params.genome].goldindels ?: null : null
if (params.goldindels) { ch_goldindels = Channel.value(file(params.goldindels, checkIfExists: true)) }

params.normpanel = params.genome ? params.human_reference[params.genome].normpanel ?: null : null
if (params.normpanel) { ch_normpanel = Channel.value(file(params.normpanel, checkIfExists: true)) }

params.genomefasta = params.genome ? params.human_reference[params.genome].genomefasta ?: null : null
if (params.genomefasta) { ch_genomefasta = Channel.value(file(params.genomefasta, checkIfExists: true)) }

params.gnomad = params.genome ? params.human_reference[params.genome].gnomad ?: null : null
if (params.gnomad) { ch_gnomad = Channel.value(file(params.gnomad, checkIfExists: true)) }


// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Input']            = params.input
summary['Genome']           = params.genome
summary['dbSNP Reference']  = params.dbsnp
summary['Golden Indels']    = params.goldindels
summary['Normal Panel']     = params.normpanel
summary['Fasta Reference']  = params.genomefasta
summary['Gnomad Reference'] = params.gnomad
summary['Adapter Refernce'] = params.adapter
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()
Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-humgen-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nibscbioinformatics/humgen Workflow Summary'
    section_href: 'https://github.com/nibscbioinformatics/humgen'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }
/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}


/*
================================================================================
                                START OF NIBSC HUMGEN PIPELINE
================================================================================
*/

//Make BWA index of reference fasta to allow alignment
process BuildBWAindexes {
    label 'process_medium'

    input:
    file(fasta) from ch_genomefasta

    output:
    file("${fasta}.*") into ch_bwaIndex

    script:
    """
    bwa index ${fasta}
    """
}

//Create sequence dictionary from reference fasta
process BuildDict {
    label 'process_medium'

    input:
    file(fasta) from ch_genomefasta

    output:
    file("${fasta.baseName}.dict") into dictBuilt

    script:
    """
    gatk --java-options "-Xmx${task.memory.toGiga()}g" \
        CreateSequenceDictionary \
        --REFERENCE ${fasta} \
        --OUTPUT ${fasta.baseName}.dict
    """
}

//Make SAMTools FAI index of reference fasta
process BuildFastaFai {
    label 'process_medium'

    input:
    file(fasta) from ch_genomefasta

    output:
    file("${fasta}.fai") into fastaFaiBuilt

    script:
    """
    samtools faidx ${fasta}
    """
}

//Build tabix index for dbSNP reference
process BuildDbsnpIndex {
    label 'process_medium'

    input:
    file(dbsnp) from ch_dbsnp

    output:
    file("${dbsnp}.tbi") into dbsnpIndexBuilt

    script:
    """
    tabix -p vcf ${dbsnp}
    """
}

//Index the gnomad germline resource
process BuildGermlineResourceIndex {
    label 'process_medium'

    input:
    file(germlineResource) from ch_gnomad

    output:
    file("${germlineResource}.tbi") into gnomadIndexBuilt

    script:
    """
    tabix -p vcf ${germlineResource}
    """
}

//tabix index for the gold indels reference file
process BuildKnownIndelsIndex {
    label 'process_medium'

    input:
    file(knownIndels) from ch_goldindels

    output:
    file("${knownIndels}.tbi") into knownIndelsIndexBuilt

    script:
    """
    tabix -p vcf ${knownIndels}
    """
}

//tabix index for panel of normals reference for mutect somatic calling
process BuildPonIndex {
    label 'process_medium'

    input:
    file(pon) from ch_normpanel

    output:
    file("${pon}.tbi") into ponIndexBuilt

    script:
    """
    tabix -p vcf ${pon}
    """
}

//QC step 1
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(name), file(reads) from ch_read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc --quiet --threads $task.cpus $reads
    """
}

//QC step 2
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}

//Output HTML from template (not report)
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

//Trimming of adapters and low-quality bases - note hardcoded parameters in command
process docutadapt {
  label 'process_medium'
  tag "trimming ${sampleprefix}"

  input:
  tuple sampleprefix, file(samples) from inputSample
  file(adapterfile) from ch_adapter

  output:
  set ( sampleprefix, file("${sampleprefix}.R1.trimmed.fastq.gz"), file("${sampleprefix}.R2.trimmed.fastq.gz") ) into (trimmingoutput1, trimmingoutput2)
  file("${sampleprefix}.trim.out") into trimouts

  script:
  """
  cutadapt -a file:${adapterfile} -A file:${adapterfile} -g file:${adapterfile} -G file:${adapterfile} -o ${sampleprefix}.R1.trimmed.fastq.gz -p ${sampleprefix}.R2.trimmed.fastq.gz ${samples[0]} ${samples[1]} -q 30,30 --minimum-length 50 --times 40 -e 0.1 --max-n 0 > ${sampleprefix}.trim.out 2> ${sampleprefix}.trim.err
  """
}

//Produce output CSV table of trimming stats for reading in R
process dotrimlog {
  publishDir "$params.outdir/stats/trimming/", mode: "copy"
  label 'process_low'

  input:
  file "logdir/*" from trimouts.toSortedList()

  output:
  file("trimming-summary.csv") into trimlogend

  script:
  """
  python $baseDir/scripts/logger.py logdir trimming-summary.csv cutadapt
  """
}

//BWA alignment of samples, and sorting to BAM format
process doalignment {
  label 'process_high'

  input:
  set (sampleprefix, file(forwardtrimmed), file(reversetrimmed)) from trimmingoutput1
  file( fastaref ) from ch_genomefasta
  file ( bwaindex ) from ch_bwaIndex

  output:
  set (sampleprefix, file("${sampleprefix}_sorted.bam") ) into sortedbam

  script:
  """
  bwa mem \
  -t ${task.cpus} \
  -R '@RG\\tID:${sampleprefix}\\tSM:${sampleprefix}\\tPL:Illumina' \
  $fastaref \
  ${forwardtrimmed} ${reversetrimmed} \
  | samtools sort -@ ${task.cpus} \
  -o ${sampleprefix}_sorted.bam -O BAM
  """
}

//NIBSC 3 - mark duplicates
process markduplicates {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(sortedbamfile) ) from sortedbam

  output:
  set ( sampleprefix, file("${sampleprefix}.marked.bam") ) into (markedbamfortable, markedbamforapply)

  """
  gatk MarkDuplicates -I $sortedbamfile -M ${sampleprefix}.metrics.txt -O ${sampleprefix}.marked.bam
  """
}

//NIBSC 4 - generate a base recalibration table using golden indels reference
process baserecalibrationtable {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(markedbamfile) ) from markedbamfortable
  file(dbsnp) from ch_dbsnp
  file(dbsnpIndex) from dbsnpIndexBuilt
  file(fasta) from ch_genomefasta
  file(fastaFai) from fastaFaiBuilt
  file(knownIndels) from ch_goldindels
  file(knownIndelsIndex) from knownIndelsIndexBuilt

  output:
  set ( sampleprefix, file("${sampleprefix}.recal_data.table") ) into recaltable

  """
  gatk BaseRecalibrator -I $markedbamfile --known-sites $dbsnp --known-sites $knownIndels -O ${sampleprefix}.recal_data.table -R $fasta
  """
}

//creating a (prefix, recaltable, bamfile) tuple for input to the following process
forrecal = recaltable.join(markedbamforapply)

//NIBSC 5 - apply previously calculated base quality score recalibration
process applybaserecalibration {
  publishDir "$params.outdir/alignments", mode: "copy"
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(recalibrationtable), file(markedbamfile) ) from forrecal

  output:
  set ( sampleprefix, file("${sampleprefix}.bqsr.bam") ) into (recalibratedforindex, recalibratedforcaller)

  """
  gatk ApplyBQSR -I $markedbamfile -bqsr $recalibrationtable -O ${sampleprefix}.bqsr.bam
  """
}

//NIBSC 6 - create a BAI indexed file from this alignment
process indexrecalibrated {
  publishDir "$params.outdir/alignments", mode: "copy"
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(bqsrfile) ) from recalibratedforindex

  output:
  set ( sampleprefix, file("${bqsrfile}.bai") ) into indexedbam

  """
  samtools index $bqsrfile
  """
}

//Make two channels with the BAM and BAI alignments for following variant calling
forcaller = recalibratedforcaller.join(indexedbam)
forcaller.into {
  forcaller1
  forcaller2
}

//NIBSC 7 - call germline variants
process haplotypecall {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(bamfile), file(baifile) ) from forcaller1
  file(dbsnp) from ch_dbsnp
  file(dbsnpIndex) from dbsnpIndexBuilt
  file(fasta) from ch_genomefasta
  file(fastaFai) from fastaFaiBuilt

  output:
  set ( sampleprefix, file("${sampleprefix}.hapcalled.vcf") ) into calledhaps

  """
  gatk HaplotypeCaller -R $fasta -O ${sampleprefix}.hapcalled.vcf -I $bamfile --native-pair-hmm-threads ${task.cpus} --dbsnp $dbsnp
  """
}

//NIBSC 8 - call somatic variants without using a paired normal tissue - refer to the panel of normals and gnomad germline resource
process mutectcall {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(bamfile), file(baifile) ) from forcaller2
  file(fasta) from ch_genomefasta
  file(fastaFai) from fastaFaiBuilt
  file(gnomad) from ch_gnomad
  file(gnomadindex) from gnomadIndexBuilt
  file(normpanel) from ch_normpanel
  file(normpanelindex) from ponIndexBuilt

  output:
  set ( sampleprefix, file("${sampleprefix}.mutcalled.vcf"), file("${sampleprefix}.mutcalled.vcf.stats") ) into calledmuts

  """
  gatk Mutect2 -R $fasta -O ${sampleprefix}.mutcalled.vcf -I $bamfile --native-pair-hmm-threads ${task.cpus} --panel-of-normals $normpanel --germline-resource $gnomad
  """
}

//NIBSC 9 - run a default filter on the mutect calls
process mutectfilter {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(mutvcf), file(mutstats) ) from calledmuts
  file(fasta) from ch_genomefasta
  file(fastafai) from fastaFaiBuilt

  output:
  set ( sampleprefix, file("${sampleprefix}.mutcalled.filtered.vcf") ) into filteredmuts

  """
  gatk FilterMutectCalls -R $fasta -V $mutvcf -O ${sampleprefix}.mutcalled.filtered.vcf
  """
}

//Join the variant calls to process filtering together
rawvars = calledhaps.join(filteredmuts)

//NIBSC 10 - separate the different kinds of variant calls to treat with different filters
process snpindelsplit {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(hapfile), file(mutfile) ) from rawvars

  output:
  set ( sampleprefix, file("${sampleprefix}.hapcalled.snp.vcf"), file("${sampleprefix}.hapcalled.indel.vcf"), file("${sampleprefix}.mutcalled.snp.vcf"), file("${sampleprefix}.mutcalled.indel.vcf") ) into splitupvars

  """
  gatk SelectVariants -V $hapfile -O ${sampleprefix}.hapcalled.snp.vcf -select-type SNP
  gatk SelectVariants -V $hapfile -O ${sampleprefix}.hapcalled.indel.vcf -select-type INDEL
  gatk SelectVariants -V $mutfile -O ${sampleprefix}.mutcalled.snp.vcf -select-type SNP
  gatk SelectVariants -V $mutfile -O ${sampleprefix}.mutcalled.indel.vcf -select-type INDEL
  """
}

//NIBSC 11 - Using hard filter rules as given as recommendations on GATK4 help pages
process hardfilter {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(hapsnp), file(hapindel), file(mutsnp), file(mutindel) ) from splitupvars
  file(fasta) from ch_genomefasta
  file(fastafai) from fastaFaiBuilt

  output:
  set ( sampleprefix, file("${sampleprefix}.germline.filtered.snp.vcf"), file("${sampleprefix}.germline.filtered.indel.vcf"), file("${sampleprefix}.somatic.filtered.snp.vcf"), file("${sampleprefix}.somatic.filtered.indel.vcf") ) into filteredvars

  """
  gatk VariantFiltration -O ${sampleprefix}.germline.filtered.snp.vcf -V $hapsnp -R $fasta --filter-name snpfilter --filter-expression "QD < 2.0 || MQ < 40.0 || FS > 60.0 || SOR > 3.0 || MQRankSum < -12.5 || ReadPosRankSum < -8.0"
  gatk VariantFiltration -O ${sampleprefix}.germline.filtered.indel.vcf -V $hapindel -R $fasta --filter-name indelfilter --filter-expression "QD < 2.0 || FS > 200.0 || SOR > 10.0 || ReadPosRankSum < -20.0"
  gatk VariantFiltration -O ${sampleprefix}.somatic.filtered.snp.vcf -V $mutsnp -R $fasta --filter-name snpfilter --filter-expression "QD < 2.0 || MQ < 40.0 || FS > 60.0 || SOR > 3.0 || MQRankSum < -12.5 || ReadPosRankSum < -8.0"
  gatk VariantFiltration -O ${sampleprefix}.somatic.filtered.indel.vcf -V $mutindel -R $fasta --filter-name indelfilter --filter-expression "QD < 2.0 || FS > 200.0 || SOR > 10.0 || ReadPosRankSum < -20.0"
  """
}

//NIBSC 12 - merging the snps and indels again
process remergevars {
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(germlinesnp), file(germlineindel), file(somaticsnp), file(somaticindel) ) from filteredvars

  output:
  set ( sampleprefix, file("${sampleprefix}.germline.vcf"), file("${sampleprefix}.germline.vcf.idx"), file("${sampleprefix}.somatic.vcf"), file("${sampleprefix}.somatic.vcf.idx") ) into (germsomvars1, germsomvars2)

  """
  gatk MergeVcfs -I $germlinesnp -I $germlineindel -O ${sampleprefix}.germline.vcf
  gatk MergeVcfs -I $somaticsnp -I $somaticindel -O ${sampleprefix}.somatic.vcf
  """
}

//NIBSC 13 - evaluating the variant calls for ti-tv ratio and so-on
process variantevaluation {
  publishDir "$params.outdir/analysis", mode: "copy"
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(germline), file(germlineindex), file(somatic), file(somaticindex) ) from germsomvars1
  file(dbsnp) from ch_dbsnp
  file(dbsnpIndex) from dbsnpIndexBuilt
  file(fasta) from ch_genomefasta
  file(fastaFai) from fastaFaiBuilt

  output:
  set ( sampleprefix, file("${sampleprefix}.germline.eval.grp"), file("${sampleprefix}.somatic.eval.grp") ) into variantevaluations

  """
  gatk VariantEval -eval $germline -O ${sampleprefix}.germline.eval.grp -R $fasta -D $dbsnp
  gatk VariantEval -eval $somatic -O ${sampleprefix}.somatic.eval.grp -R $fasta -D $dbsnp
  """
}

//NIBSC 14 - adding annotation to variant calls for effect prediction - uses snpEff installed settings for hg19
process effectprediction {
  publishDir "$params.outdir/analysis", mode: "copy"
    tag "$name"
    label 'process_medium'

  input:
  set ( sampleprefix, file(germline), file(germlineindex), file(somatic), file(somaticindex) ) from germsomvars2

  output:
  set ( sampleprefix, file("${sampleprefix}.germline.annotated.vcf"), file("${sampleprefix}.somatic.annotated.vcf") ) into annotatedvars

  """
  snpEff -Xmx8g hg19 $germline > ${sampleprefix}.germline.annotated.vcf
  snpEff -Xmx8g hg19 $somatic > ${sampleprefix}.somatic.annotated.vcf
  """
}





/*
 * STEP 3 - Output Description HTML

process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}
*/

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nibscbioinformatics/humgen] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nibscbioinformatics/humgen] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nibscbioinformatics/humgen] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nibscbioinformatics/humgen] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nibscbioinformatics/humgen] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nibscbioinformatics/humgen] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nibscbioinformatics/humgen]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nibscbioinformatics/humgen]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nibscbioinformatics/humgen v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

def readInputFile(tsvFile) {
    Channel.from(tsvFile)
        .splitCsv(sep: '\t')
        .map { row ->
            def idSample  = row[0]
            def gender     = row[1]
            def status     = row[2].toInteger()
            def file1      = returnFile(row[3])
            def file2      = "null"
            if (hasExtension(file1, "fastq.gz") || hasExtension(file1, "fq.gz")) {
                checkNumberOfItem(row, 5)
                file2 = returnFile(row[4])
                if (!hasExtension(file2, "fastq.gz") && !hasExtension(file2, "fq.gz")) exit 1, "File: ${file2} has the wrong extension. See --help for more information"
            }
            // else if (hasExtension(file1, "bam")) checkNumberOfItem(row, 5)
            // here we only use this function for fastq inputs and therefore we suppress bam files
            else "No recognisable extension for input file: ${file1}"
            [idSample, gender, status, file1, file2]
        }
}

// #### SAREK FUNCTIONS #########################
def checkNumberOfItem(row, number) {
    if (row.size() != number) exit 1, "Malformed row in TSV file: ${row}, see --help for more information"
    return true
}

def hasExtension(it, extension) {
    it.toString().toLowerCase().endsWith(extension.toLowerCase())
}

// Return file if it exists
def returnFile(it) {
    if (!file(it).exists()) exit 1, "Missing file in TSV file: ${it}, see --help for more information"
    return file(it)
}

// Return status [0,1]
// 0 == Control, 1 == Case
def returnStatus(it) {
    if (!(it in [0, 1])) exit 1, "Status is not recognized in TSV file: ${it}, see --help for more information"
    return it
}

// ############### OTHER UTILS ##########################

// Example usage: defaultIfInexistent({myVar}, "default")
def defaultIfInexistent(varNameExpr, defaultValue) {
    try {
        varNameExpr()
    } catch (exc) {
        defaultValue
    }
}
