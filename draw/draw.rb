require_relative './canvas'
require_relative './stamp'

template = File.read "#{File.dirname(__FILE__)}/draw.html"
stamps = [
  Stamp::Star,
  Stamp::Sun,
  Stamp::Smile,
  Stamp::Cat,
  Stamp::Fish,
  Stamp::Penguin
]
canvas = Canvas.new

get '/draw' do
  stream do |out|
    buffer = []
    flush = lambda do
      out.write buffer.join
      buffer = []
    end
    begin
      channel = Channel.new
      action_path = channel.path
      dump_button = %(
        <form target=a method=post action={{action_path}} style='position:fixed;left:0;top:0;z-index:65536;'>
          <input type=submit name=type value=dump>
        </form>
      ) if params[:dump]
      html = template.gsub /{{[^{]+}}/ do |pattern|
        exp = pattern[2...-2]
        eval exp
      end

      buffer << html
      tool = 'curve'
      stamp = 0
      stamp_once_opened = false
      color = '#000'
      strokes = []

      queue = Queue.new
      Thread.new { loop { sleep 1;queue << nil } }
      Thread.new { loop { queue << channel.deq(timeout: nil) } }
      callback = -> type, data { queue << { type: type, data: data } }
      canvas.listen callback

      cancel_curve = ->{
        strokes = []
        buffer << %(<style>.pnt{display:none}</style>)
      }

      loop do
        cmd = queue.deq
        unless cmd
          buffer << "\n"
          flush.call
          next
        end
        case cmd[:type]
        when 'tool'
          cancel_curve.call
          case cmd[:tool]
          when 'eraser'
            buffer << "<style>##{tool}{border-color:silver}</style>"
            buffer << "<style>#eraser{border-color:black}</style>"
            tool = 'eraser'
          when 'curve'
            buffer << "<style>##{tool}{border-color:silver}</style>"
            buffer << "<style>#curve{border-color:black}</style>"
            tool = 'curve'
          when 'color'
            buffer << "<style>#color_modal{display:flex}</style>"
          when 'stamp'
            if tool == 'stamp' || !stamp_once_opened
              stamp_once_opened = true
              buffer << "<style>#stamp_modal{display:flex}</style>"
            end
            if tool != 'stamp'
              buffer << "<style>##{tool}{border-color:silver}</style>"
              tool = 'stamp'
              buffer << "<style>#stamp{border-color:black}</style>"
            end
          end
        when 'dump'
          canvas.dump
        when 'canvas'
          p = Point.new cmd[:x].to_i, cmd[:y].to_i
          case tool
          when 'curve'
            if strokes[-1] && (strokes[-1][0].x-p.x)**2+(strokes[-1][0].y-p.y)**2<8**2
              cancel_curve.call
            else
              buffer << %(<style>.pnt{display:block;left:#{p.x}px;top:#{p.y}px}</style>)
              strokes << [p]
              if strokes.size == 1
                circle = Circle.new strokes[0][0], color: color
                id, z = canvas.add([circle]).first
                strokes[0][1] = id
                strokes[0][2] = z
              end
              if strokes.size >= 2
                points = strokes.map(&:first)
                xs, ys = [:x, :y].map { |axis| Bezier.bezparam1d points.map(&axis) }
                z = strokes[0][2]
                replaces = []
                adds = []
                (strokes.size - 4 .. strokes.size - 2).each do |i|
                  next if i < 0
                  pa, pb = points[i], points[i+1]
                  ca = Point.new pa.x+xs[i]/3, pa.y+ys[i]/3
                  cb = Point.new pb.x-xs[i+1]/3, pb.y-ys[i+1]/3
                  bez = Bezier.new pa, ca, cb, pb, color: color
                  if strokes[i][1]
                    replaces << [i, [strokes[i][1], bez, z]]
                    # id, z = canvas.replace strokes[i][1], bez, z: z
                  else
                    adds << [i, bez]
                  end
                end
                idzupdates = []
                unless replaces.empty?
                  idzbs = canvas.replace replaces.map(&:last)
                  idzupdates += replaces.map(&:first).zip(idzbs)
                end
                unless adds.empty?
                  idzbs = canvas.add adds.map(&:last), zs: adds.map { z }
                  idzupdates += adds.map(&:first).zip(idzbs)
                end
                idzupdates.each do |i, (id, z, _)|
                  if id && z
                    strokes[i][1] = id
                    strokes[i][2] = z
                  end
                end
              end
            end
          when 'eraser'
            canvas.erase p, 48
          when 'stamp'
            size = 128
            offset = Point.new(p.x-size/2, p.y-size/2)
            canvas.add stamps[stamp].beziers(offset: offset, scale: size, color: color)
          end
        when 'initial'
          cmd[:data].each do |id, (z, bez)|
            buffer << bez.to_svg(id: id, z: z)
          end
        when 'add'
          cmd[:data].each do |id, z, bez|
            buffer << bez.to_svg(id: id, z: z)
          end
        when 'remove'
          cmd[:data].each do |id|
            buffer << %(<style>##{id}{display:none}</style>)
          end
        when 'color'
          color = cmd[:color]
          buffer << "<style>#color{background:#{cmd[:color]}}</style>"
          buffer << "<style>#color_modal{display:none}</style>"
        when 'stamp'
          buffer << "<style>.current-stamp.stamp#{stamp}{display:none;}</style>"
          stamp = cmd[:stamp].to_i if stamps[cmd[:stamp].to_i]
          buffer << "<style>.current-stamp.stamp#{stamp}{display:block;}</style>"
          buffer << "<style>#stamp_modal{display:none}</style>"
        when 'close'
          buffer << "<style>##{cmd[:target]}_modal{display:none}</style>"
        end
        flush.call
      end
    rescue => e
      canvas.unlisten callback
      queue.close
      channel.close
      raise e
    end
  end
end
