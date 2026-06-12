# frozen_string_literal: true

module Nox
  # Plain-text mirror of what the app draws each frame.
  #
  # ratatui_ruby's get_cell_at / get_buffer_content are TestBackend-only —
  # on a live Crossterm terminal the draw snapshot carries no buffer and every
  # read raises Error::Terminal. The selection feature needs "what text is at
  # (x, y)", so this grid records the text side of every widget nox renders
  # (via MappingFrame) and answers that question without touching the buffer.
  #
  # Cells: nil = untouched, "" = continuation of a wide char, else one char.
  # Untouched cells read back as spaces in +slice+ but split +segments+, so
  # the selection overlay never paints over borders or empty gaps.
  class ShadowGrid
    attr_reader :width, :height

    def initialize(width, height)
      @width  = width
      @height = height
      @rows = Array.new(height) { Array.new(width) }
    end

    # Writes +text+ at column x, row y, clipped to max_width display cells
    # (and to the grid). Wide chars take two cells; a wide char that does not
    # fully fit is dropped. Multi-codepoint grapheme clusters degrade to
    # per-char placement — acceptable for Notion task text.
    def write(x, y, text, max_width: nil)
      row = @rows[y]
      return unless row && text

      limit = [x + (max_width || @width), @width].min
      col = x
      text.each_char do |ch|
        w = char_width(ch)
        break if col + w > limit

        row[col] = ch
        row[col + 1] = "" if w == 2
        col += w
      end
    end

    # Reads columns x1..x2 of row y as text. Untouched cells become spaces;
    # continuation cells are skipped (a wide char straddling x1 is dropped).
    def slice(x1, x2, y)
      row = @rows[y]
      return "" unless row && y >= 0

      x1 = [x1, 0].max
      x2 = [x2, @width - 1].min
      return "" if x1 > x2

      (x1..x2).filter_map { |x| cell_text(row[x]) }.join
    end

    # Contiguous runs of written cells within x1..x2 → [[x_start, text], ...].
    # Used by the selection overlay so only real content gets re-styled.
    def segments(x1, x2, y)
      row = @rows[y]
      return [] unless row && y >= 0

      x1 = [x1, 0].max
      x2 = [x2, @width - 1].min
      result = []
      run_start = nil
      run = nil
      (x1..x2).each do |x|
        if row[x].nil?
          result << [run_start, run] if run_start
          run_start = nil
        else
          unless run_start
            run_start = x
            run = +""
          end
          run << row[x]
        end
      end
      result << [run_start, run] if run_start
      result
    end

    def clear_region(x, y, width, height)
      (y...(y + height)).each do |ry|
        row = @rows[ry]
        next unless row

        (x...[x + width, @width].min).each { |rx| row[rx] = nil }
      end
    end

    # Mirrors a widget render into the grid. Knows the two text-bearing
    # widgets nox uses (Paragraph, List) plus Clear; everything else
    # (Scrollbar, custom overlay widgets) is decorative and ignored.
    def record(widget, area, state = nil)
      case widget
      when RatatuiRuby::Widgets::Clear
        clear_region(area.x, area.y, area.width, area.height)
      when RatatuiRuby::Widgets::Paragraph
        record_block_title(widget.block, area)
        x, y, w, h = inner_rect(area, widget.block)
        lines_of(widget.text).each_with_index do |line, i|
          break if i >= h

          write(x, y + i, plain_text(line), max_width: w)
        end
      when RatatuiRuby::Widgets::List
        record_block_title(widget.block, area)
        x, y, w, h = inner_rect(area, widget.block)
        offset = (state.respond_to?(:offset) ? state.offset : widget.offset) || 0
        indent = list_indent(widget)
        items = Array(widget.items)[offset, h] || []
        items.each_with_index do |item, i|
          write(x + indent, y + i, plain_text(item), max_width: w - indent)
        end
      end
    end

    private

    def cell_text(cell)
      return " " if cell.nil?
      return nil if cell == ""

      cell
    end

    def char_width(char)
      char.ascii_only? ? 1 : [RatatuiRuby._text_width(char), 1].max
    end

    def list_indent(widget)
      return 0 unless widget.highlight_spacing == :always && widget.highlight_symbol

      RatatuiRuby._text_width(widget.highlight_symbol)
    end

    # [x, y, width, height] inside the block's borders.
    def inner_rect(area, block)
      borders = Array(block&.borders)
      all = borders.include?(:all)
      left   = all || borders.include?(:left)   ? 1 : 0
      right  = all || borders.include?(:right)  ? 1 : 0
      top    = all || borders.include?(:top)    ? 1 : 0
      bottom = all || borders.include?(:bottom) ? 1 : 0
      [area.x + left, area.y + top, area.width - left - right, area.height - top - bottom]
    end

    # A bordered block renders its title on the top border row at x+1.
    def record_block_title(block, area)
      title = block&.title
      return unless title && !title.empty?

      borders = Array(block.borders)
      return unless borders.include?(:all) || borders.include?(:top)

      write(area.x + 1, area.y, title, max_width: area.width - 2)
    end

    def lines_of(text)
      case text
      when String then text.split("\n", -1)
      when Array  then text
      when nil    then []
      else [text]
      end
    end

    def plain_text(line)
      case line
      when String then line
      else
        if line.respond_to?(:spans)
          line.spans.map { |s| plain_text(s) }.join
        elsif line.respond_to?(:content)
          line.content.to_s
        else
          line.to_s
        end
      end
    end
  end

  # Frame wrapper that mirrors every rendered widget into a ShadowGrid.
  # Render methods keep calling frame.render_widget unchanged.
  class MappingFrame
    def initialize(frame, shadow)
      @frame  = frame
      @shadow = shadow
    end

    def area
      @frame.area
    end

    def render_widget(widget, area)
      @frame.render_widget(widget, area)
      @shadow.record(widget, area)
    end

    def render_stateful_widget(widget, area, state)
      @frame.render_stateful_widget(widget, area, state)
      @shadow.record(widget, area, state)
    end

    def set_cursor_position(x, y)
      @frame.set_cursor_position(x, y)
    end
  end
end
