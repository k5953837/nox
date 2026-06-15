# frozen_string_literal: true

module Nox
  # Mouse-drag rectangular selection state. Pure data — no I/O.
  #
  # Coordinates are terminal cells (0-indexed). The selection is defined by
  # an anchor (where the drag started) and a cursor (where it is now); +rect+
  # normalizes the two corners so backward drags behave like forward ones.
  class Selection
    def initialize
      clear
    end

    def start(x, y, max_x: nil, max_y: nil)
      @max_x = max_x
      @max_y = max_y
      @anchor = [clamp(x, max_x), clamp(y, max_y)]
      @cursor = @anchor.dup
    end

    def update(x, y)
      return unless active?

      @cursor = [clamp(x, @max_x), clamp(y, @max_y)]
    end

    def clear
      @anchor = nil
      @cursor = nil
    end

    def active?
      !@anchor.nil?
    end

    # => [x_min, y_min, x_max, y_max] or nil when inactive
    def rect
      return nil unless active?

      x1, y1 = @anchor
      x2, y2 = @cursor
      [[x1, x2].min, [y1, y2].min, [x1, x2].max, [y1, y2].max]
    end

    def single_cell?
      active? && @anchor == @cursor
    end

    private

    def clamp(value, max)
      value = value.negative? ? 0 : value
      max ? [value, max].min : value
    end
  end

  # Custom widget that re-draws the selected cells with reversed style.
  # rows: [[x, y, string], ...] — strings mirrored from the current frame's
  # ShadowGrid, so the overlay never changes what's underneath, only its style.
  class SelectionOverlay
    REVERSED = { modifiers: [:reversed].freeze }.freeze

    def initialize(rows)
      @rows = rows
    end

    def render(_area)
      @rows.map { |x, y, str| RatatuiRuby::Draw.string(x, y, str, REVERSED) }
    end
  end
end
