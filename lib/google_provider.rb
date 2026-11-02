# frozen_string_literal: true

require 'cgi'
require 'json'
require 'tempfile'
require 'uri'

require_relative 'provider'

# Google Translate, talked to through the batchexecute RPC its web UI uses,
# with speech from the endpoint behind translate.google.com's speaker button.
#
# Ported from upstream's dialect/providers/modules/google.py.
#
# Upstream gets text-to-speech from the `gtts` Python package: it reads its
# supported-language table out of `gtts.lang` and hands the request to
# `gTTS.write_to_fp`. There is no Ruby equivalent, so the port talks to the
# same /translate_tts endpoint gtts does, with gtts's `tw-ob` client and its
# 100-character chunking, and carries gtts's language table as
# TTS_LANGUAGES. Codes that table spells the old way (`iw`, `jw`) are
# normalized through Define::LANG_ALIASES like any other.
class GoogleProvider < Provider
  RPC_ID = 'MkEWBc'

  # Predefined path used to make Google Translate requests.
  TRANSLATE_RPC_PATH = '/_/TranslateWebserverUi/data/batchexecute'

  # The endpoint and client gtts uses for speech, and its per-request text
  # limit.
  SPEECH_HOST = 'translate.google.com'
  SPEECH_PATH = '/translate_tts'
  SPEECH_CLIENT = 'tw-ob'
  SPEECH_CHARS_LIMIT = 100

  HEADERS = {
    'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    'Referer'    => 'https://translate.google.com',
  }.freeze

  TRANSLATE_TLDS = [
    '.ac', '.ad', '.ae', '.al', '.am', '.as',
    '.at', '.az', '.ba', '.be', '.bf', '.bg',
    '.bi', '.bj', '.bs', '.bt', '.by', '.ca',
    '.cat', '.cc', '.cd', '.cf', '.cg', '.ch',
    '.ci', '.cl', '.cm', '.cn', '.co.ao', '.co.bw',
    '.co.ck', '.co.cr', '.co.id', '.co.il', '.co.in', '.co.jp',
    '.co.ke', '.co.kr', '.co.ls', '.co.ma', '.co.mz', '.co.nz',
    '.co.th', '.co.tz', '.co.ug', '.co.uk', '.co.uz', '.co.ve',
    '.co.vi', '.co.za', '.co.zm', '.co.zw', '.com.af', '.com.ag',
    '.com.ai', '.com.ar', '.com.au', '.com.bd', '.com.bh', '.com.bn',
    '.com.bo', '.com.br', '.com.bz', '.com.co', '.com.cu', '.com.cy',
    '.com.do', '.com.ec', '.com.eg', '.com.et', '.com.fj', '.com.gh',
    '.com.gi', '.com.gt', '.com.hk', '.com.jm', '.com.kh', '.com.kw',
    '.com.lb', '.com.ly', '.com.mm', '.com.mt', '.com.mx', '.com.my',
    '.com.na', '.com.ng', '.com.ni', '.com.np', '.com.om', '.com.pa',
    '.com.pe', '.com.pg', '.com.ph', '.com.pk', '.com.pr', '.com.py',
    '.com.qa', '.com.sa', '.com.sb', '.com.sg', '.com.sl', '.com.sv',
    '.com.tj', '.com.tr', '.com.tw', '.com.ua', '.com.uy', '.com.vc',
    '.com.vn', '.com', '.cv', '.cz', '.de', '.dj',
    '.dk', '.dm', '.dz', '.ee', '.es', '.fi',
    '.fm', '.fr', '.ga', '.ge', '.gg', '.gl',
    '.gm', '.gp', '.gr', '.gy', '.hn', '.hr',
    '.ht', '.hu', '.ie', '.im', '.iq', '.is',
    '.it', '.je', '.jo', '.kg', '.ki', '.kz',
    '.la', '.li', '.lk', '.lt', '.lu', '.lv',
    '.md', '.me', '.mg', '.mk', '.ml', '.mn',
    '.ms', '.mu', '.mv', '.mw', '.ne', '.nl',
    '.no', '.nr', '.nu', '.pl', '.pn', '.ps',
    '.pt', '.ro', '.rs', '.ru', '.rw', '.sc',
    '.se', '.sh', '.si', '.sk', '.sm', '.sn',
    '.so', '.sr', '.st', '.td', '.tg', '.tk',
    '.tl', '.tm', '.tn', '.to', '.tt', '.us',
    '.vg', '.vu', '.ws',
  ].freeze

  # The languages gtts.lang reports for text-to-speech.
  TTS_LANGUAGES = %w[
    af ar bg bn bs ca cs cy da de el en eo es et fi fr gu hi hr hu hy id is it
    iw ja jw km kn ko la lv mk ml mr ms my ne nl no pl pt ro ru si sk sq sr su
    sv sw ta te th tl tr uk ur vi zh-CN zh-TW
  ].freeze

  def self.provider_name = 'google'
  def self.prettyname = 'Google'

  def self.capabilities = ProviderCapability::TRANSLATION | ProviderCapability::TTS

  def self.features
    ProviderFeature::DETECTION | ProviderFeature::MISTAKES | ProviderFeature::PRONUNCIATION
  end

  DEFAULTS = {
    instance_url: '',
    api_key:      '',
    src_langs:    %w[en fr es de],
    dest_langs:   %w[fr es de en],
  }.freeze

  def self.defaults = DEFAULTS

  def initialize(**kwargs)
    super

    @chars_limit = 2000
  end

  def langs_url
    format_url(translate_host('.com'), '/translate_a/l', { 'client' => 't', 'alpha' => 'true' })
  end

  # Upstream appends the query to a url that already ends in "?" and lets
  # format_url add its own; the port composes host, path and params once.
  def translate_url
    format_url(
      translate_host,
      TRANSLATE_RPC_PATH,
      {
        'rpcids'       => RPC_ID,
        'bl'           => 'boq_translate-webserver_20201207.13_p0',
        'soc-app'      => '1',
        'soc-platform' => '1',
        'soc-device'   => '1',
        'rt'           => 'c',
      },
    )
  end

  def init_trans
    get(langs_url, headers: HEADERS, check_common: false).then do |response|
      response.fetch('tl').each { |code, name| add_lang(code, name) }
    end
  rescue KeyError, TypeError, NoMethodError => exc
    raise UnexpectedError, exc.message
  end

  def init_tts
    TTS_LANGUAGES.each { |code| add_lang(code, trans_src: false, trans_dest: false, tts: true) }
  end

  def translate(request)
    denormalize_lang(request.src, request.dest).then do |src_lang, dest_lang|
      post(
        translate_url,
        data:         { 'f.req' => build_rpc_request(request.text, src_lang, dest_lang) },
        headers:      HEADERS,
        form:         true,
        check_common: false,
        return_json:  false,
      ).then { |response| translation_from(
        response,
        request,
        src_lang,
        dest_lang,
      ) }
    end
  end

  # Speech comes back as MP3 in SPEECH_CHARS_LIMIT-sized pieces, which play as
  # one file once concatenated.
  def speech(text, language)
    denormalize_lang(language).then do |(lang)|
      speech_chunks(text).then do |chunks|
        Tempfile.new(['dialect-speech', '.mp3'], binmode: true).tap do |file|
          chunks.each_with_index do |chunk, index|
            file.write(
              speech_chunk(
                chunk,
                lang,
                index,
                chunks.length,
              ),
            )
          end

          file.rewind
        end
      end
    end
  end

  private

    def translate_host(tld = nil)
      "translate.google#{tld || TRANSLATE_TLDS.sample}"
    end

    def build_rpc_request(text, src, dest)
      JSON.generate(
        [[[RPC_ID, JSON.generate([[text, src, dest, true], [nil]]), nil, 'generic']]],
      )
    end

    def translation_from(response, request, src_lang, dest_lang)
      JSON.parse(rpc_payload(response.to_s)).then do |data|
        JSON.parse(dig_in(data, 0, 2).to_s).then do |parsed|
          check_langs(parsed, src_lang, dest_lang)
          build_translation(parsed, request, src_lang)
        end
      end
    rescue UnexpectedError
      raise
    rescue StandardError => exc
      raise UnexpectedError, exc.message
    end

    # The batchexecute response is a length-prefixed stream of JSON chunks.
    # Upstream finds the chunk carrying the RPC id, then accumulates lines
    # until the square brackets outside of strings balance.
    def rpc_payload(body)
      body.split("\n").reduce(['', false, 0, 0]) do |(payload, token_found, opened, closed), line|
        if opened.positive? && opened == closed
          [payload, token_found, opened, closed]
        else
          accumulate(
            payload,
            token_found,
            opened,
            closed,
            line,
          )
        end
      end.first
    end

    def accumulate(payload, token_found, opened, closed, line)
      (token_found || line[0, 30].to_s.include?("\"#{RPC_ID}\"")).then do |found|
        if found
          count_brackets(line, opened, closed).then do |(new_opened, new_closed)|
            [payload + line, found, new_opened, new_closed]
          end
        else
          [payload, found, opened, closed]
        end
      end
    end

    # Counts square brackets that are not inside a JSON string, so a bracket
    # in the translated text does not throw the balance off.
    def count_brackets(line, opened, closed)
      line.each_char.with_index.reduce([opened, closed, false]) do |(open_count, close_count, in_string), (char, i)|
        if char == '"' && line[[0, i - 1].max] != '\\'
          [open_count, close_count, !in_string]
        elsif in_string
          [open_count, close_count, in_string]
        else
          case char
          when '[' then [open_count + 1, close_count, in_string]
          when ']' then [open_count, close_count + 1, in_string]
          else [open_count, close_count, in_string]
          end
        end
      end.first(2)
    end

    # Python reads a missing or mistyped path as IndexError/TypeError and
    # moves on; this does the same for the parsed RPC payload.
    def dig_in(data, *path)
      path.reduce(data) do |value, key|
        if value.is_a?(Array) && key.is_a?(Integer)
          value[key]
        end
      end
    end

    def check_langs(parsed, src_lang, dest_lang)
      unless dig_in(
        parsed,
        1,
        -1,
        1,
      ) == src_lang
        raise UnexpectedError, 'source language mismatch'
      end

      unless dig_in(
        parsed,
        1,
        -1,
        2,
      ) == dest_lang
        raise UnexpectedError, 'destination language mismatch'
      end
    end

    def build_translation(parsed, request, src_lang)
      Translation.new(
        text:          translated_text(parsed),
        original:      request,
        detected:      detected_lang(parsed, src_lang),
        mistakes:      mistake_for(
          dig_in(
            parsed,
            0,
            1,
            0,
            0,
            1,
          ),
        ),
        pronunciation: TranslationPronunciation.new(
          src:  dig_in(parsed, 0, 0),
          dest: dig_in(
            parsed,
            1,
            0,
            0,
            1,
          ),
        ),
      )
    end

    # The translation arrives split into parts, which are joined with a space
    # except where a part is itself whitespace.
    def translated_text(parsed)
      translated_parts(parsed).each_with_index.map do |part, index|
        if index.positive? && !part.match?(/\A\s+\z/)
          " #{part}"
        else
          part
        end
      end.join
    end

    def translated_parts(parsed)
      dig_in(
        parsed,
        1,
        0,
        0,
        5,
      ).then do |parts|
        if parts.is_a?(Array)
          parts.map { |part| dig_in(part, 0).to_s }
        else
          [dig_in(
            parsed,
            1,
            0,
            1,
            0,
          ).to_s
]
        end
      end
    end

    # When the request asked for detection, the detected code replaces "auto",
    # but only if it is one the provider knows.
    def detected_lang(parsed, src_lang)
      if src_lang == 'auto' && src_languages.include?(dig_in(parsed, 0, 2))
        dig_in(parsed, 0, 2)
      else
        dig_in(
          parsed,
          1,
          -1,
          1,
        )
      end
    end

    # Google marks the correction with <em>; Dialect shows Pango markup.
    def mistake_for(mistake)
      if mistake.nil? || mistake.to_s.empty?
        nil
      else
        mistake.gsub('<em>', '<b>').gsub('</em>', '</b>').then do |markup|
          TranslationMistake.new(markup: markup, text: strip_html_tags(mistake))
        end
      end
    end

    def strip_html_tags(text)
      CGI.escapeHTML(text.gsub(/(<!--.*?-->|<[^>]*>)/m, ''))
    end

    # Splits on whitespace into pieces of at most SPEECH_CHARS_LIMIT
    # characters, which is the limit gtts chunks to.
    def speech_chunks(text)
      text.to_s.split(/\s+/).reject(&:empty?).reduce([]) do |chunks, word|
        chunks.tap do
          if chunks.empty? || "#{chunks.last} #{word}".length > SPEECH_CHARS_LIMIT
            chunks << word
          else
            chunks[-1] = "#{chunks.last} #{word}"
          end
        end
      end.then do |chunks|
        if chunks.empty?
          ['']
        else
          chunks
        end
      end
    end

    def speech_chunk(chunk, lang, index, total)
      get(
        speech_url(
          chunk,
          lang,
          index,
          total,
        ),
        headers:      HEADERS,
        check_common: false,
        return_json:  false,
      )
    end

    def speech_url(chunk, lang, index, total)
      format_url(
        SPEECH_HOST,
        SPEECH_PATH,
        {
          'ie'       => 'UTF-8',
          'q'        => chunk,
          'tl'       => lang,
          'total'    => total.to_s,
          'idx'      => index.to_s,
          'textlen'  => chunk.length.to_s,
          'client'   => SPEECH_CLIENT,
          'prev'     => 'input',
          'ttsspeed' => '1',
        },
      )
    end
end
