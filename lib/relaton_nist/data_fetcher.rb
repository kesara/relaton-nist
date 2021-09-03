# frozen_string_literal: true

# require 'English'
# require 'mechanize'
# require "fileutils"
require "yaml"
# require "open-uri"
# require "nokogiri"
# require "relaton_nist"

module RelatonNist
  class DataFetcher
    RELATION_TYPES = {
      "replaces" => "obsoletes",
      "isVersionOf" => "editionOf",
      "hasTranslation" => "hasTranslation",
      "isTranslationOf" => "translatedFrom",
      "hasPreprint" => "hasReprint",
      "isSupplementTo" => "complements",
    }.freeze
    URL = "https://raw.githubusercontent.com/usnistgov/NIST-Tech-Pubs/nist-pages/xml/allrecords.xml"

    def initialize(output, format)
      @output = output
      @format = format
    end

    def parse_docid(doc)
      doi = doc.at("doi_data/doi").text
      id = doc.at("publisher_item/item_number", "publisher_item/identifier").text.sub(%r{^/}, "")
      case doi
      when "10.6028/NBS.CIRC.12e2revjune" then id.sub!("13e", "12e")
      when "10.6028/NBS.CIRC.36e2" then id.sub!("46e", "36e")
      when "10.6028/NBS.HB.67suppJune1967" then id.sub!("1965", "1967")
      when "10.6028/NBS.HB.105-1r1990" then id.sub!("105-1-1990", "105-1r1990")
      when "10.6028/NIST.HB.150-10-1995" then id.sub!(/150-10$/, "150-10-1995")
      end
      [{ type: "NIST", id: id }, { type: "DOI", id: doi }]
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<RelatonBib::DocumentIdentifier>]
    def fetch_docid(doc)
      parse_docid(doc).map do |id|
        RelatonBib::DocumentIdentifier.new(type: id[:type], id: id[:id])
      end
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [RelatonBib::TypedTitleStringCollection, Array]
    def fetch_title(doc)
      t = doc.xpath("titles/title|titles/subtitle")
      return [] unless t.any?

      RelatonBib::TypedTitleString.from_string t.map(&:text).join(" "), "en", "Latn"
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<RelatonBib::BibliographicDate>]
    def fetch_date(doc)
      doc.xpath("publication_date|approval_date").map do |dt|
        on = dt.at("year").text
        if (m = dt.at "month")
          on += "-#{m.text}"
          d = dt.at "day"
          on += "-#{d.text}" if d
        end
        type = dt.name == "publication_date" ? "published" : "confirmed"
        RelatonBib::BibliographicDate.new(type: type, on: on)
      end
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [String]
    def fetch_edition(doc)
      doc.at("edition_number")&.text
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<Hash>]
    def fetch_relation(doc)
      ns = "http://www.crossref.org/relations.xsd"
      doc.xpath("./ns:program/ns:related_item", ns: ns).map do |rel|
        doi = rel.at_xpath("ns:intra_work_relation|ns:inter_work_relation", ns: ns)
        # ref = doi_to_id doi.text
        # ref, = parse_docid doc
        fref = RelatonBib::FormattedRef.new content: doi.text
        bibitem = RelatonBib::BibliographicItem.new formattedref: fref
        type = RELATION_TYPES[doi["relationship-type"]]
        { type: type, bibitem: bibitem }
      end
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<RelatonBib::TypedUri>]
    def fetch_link(doc)
      url = doc.at("doi_data/resource").text
      [RelatonBib::TypedUri.new(type: "doi", content: url)]
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<RelatonBib::FormattedString>]
    def fetch_abstract(doc)
      doc.xpath("jats:abstract/jats:p", "jats" => "http://www.ncbi.nlm.nih.gov/JATS1").map do |a|
        RelatonBib::FormattedString.new(content: a.text, language: doc["language"], script: "Latn")
      end
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<Hash>]
    def fetch_contributor(doc) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      contribs = doc.xpath("contributors/person_name").map do |p|
        forename = []
        initial = []
        p.at("given_name")&.text&.split&.each do |fn|
          if /^(?<init>\w)\.?$/ =~ fn
            initial << RelatonBib::LocalizedString.new(init, doc["language"], "Latn")
          else
            forename << RelatonBib::LocalizedString.new(fn, doc["language"], "Latn")
          end
        end
        sname = p.at("surname").text
        surname = RelatonBib::LocalizedString.new sname, doc["language"], "Latn"
        initial = []
        ident = p.xpath("ORCID").map do |id|
          RelatonBib::PersonIdentifier.new "orcid", id.text
        end
        fullname = RelatonBib::FullName.new(
          surname: surname, forename: forename, initial: initial, identifier: ident,
        )
        person = RelatonBib::Person.new name: fullname
        { entity: person, role: [{ type: p["contributor_role"] }] }
      end
      contribs + doc.xpath("publisher").map do |p|
        abbr = p.at("../institution/institution_acronym")&.text
        org = RelatonBib::Organization.new(name: p.at("publisher_name").text, abbreviation: abbr)
        { entity: org, role: [{ type: "publisher" }] }
      end
    end

    # @param doc [Nokogiri::XML::Element]
    # @return [Array<String>]
    def fetch_place(doc)
      doc.xpath("institution/institution_place").map(&:text)
    end

    #
    # Save document
    #
    # @param bib [RelatonNist::NistBibliographicItem]
    #
    def write_file(bib) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      id = bib.docidentifier[0].id.gsub(%r{[/\s:.]}, "_").upcase.sub(/^NIST_IR/, "NISTIR")
      file = File.join(@output, "#{id}.#{@format}")
      if File.exist? file
        warn "File #{file} exists. Docid: #{bib.docidentifier[0].id}"
        # warn "Link: #{bib.link.detect { |l| l.type == 'src' }.content}"
      else
        output = case @format
                 when "yaml" then bib.to_hash.to_yaml
                 when "xml" then bib.to_xml bibdata: true
                 end
        File.write file, output, encoding: "UTF-8"
      end
    end

    #
    # Create a document instance an save it.
    #
    # @param doc [Nokogiri::XML::Element]
    #
    # @raise [StandardError]
    #
    def parse_doc(doc) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      # mtd = doc.at('doi_record/report-paper/report-paper_metadata')
      item = RelatonNist::NistBibliographicItem.new(
        type: "standard", docid: fetch_docid(doc), title: fetch_title(doc),
        link: fetch_link(doc), abstract: fetch_abstract(doc),
        date: fetch_date(doc), edition: fetch_edition(doc),
        contributor: fetch_contributor(doc), relation: fetch_relation(doc),
        place: fetch_place(doc),
        language: [doc["language"]], script: ["Latn"], doctype: "standard"
      )
      write_file item
    rescue StandardError => e
      warn "Document: #{doc.at('doi').text}"
      warn e.message
      raise e
    end

    #
    # Fetch all the documnts from dataset
    #
    def fetch # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      t1 = Time.now
      puts "Started at: #{t1}"

      docs = Nokogiri::XML OpenURI.open_uri URL
      FileUtils.mkdir @output unless Dir.exist? @output
      FileUtils.rm Dir[File.join(@output, "*.#{@format}")]
      docs.xpath("/body/query/doi_record/report-paper/report-paper_metadata")
        .each { |doc| parse_doc doc }

      t2 = Time.now
      puts "Stopped at: #{t2}"
      puts "Done in: #{(t2 - t1).round} sec."
    rescue StandardError => e
      warn e.message
    end

    #
    # Fetch all the documnts from dataset
    #
    # @param [String] output foldet name to save the documents
    # @param [String] format format to save the documents
    #
    def self.fetch(output: "data", format: "yaml")
      new(output, format).fetch
    end
  end
end
