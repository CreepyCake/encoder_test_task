require 'json'

class String

  #привести строку вида ">=10" к числу 10
  def to_integer
    i = self.split('').map { |n| n.to_i }
    i.shift while i[0] == 0
    i.join.to_i
  end

end

class Encoder

  def initialize(filename)
    @json = JSON.parse(File.read(filename))
    @histogram = {} #хэш для операндов, ключ - операнд, значение - сколько раз операнд встречается
    @opcode = {} #хэш для кодов операций
    @f = {} #хэш для форматов
    @bits = {} #хэш для хранения старшего и младшего битов для каждого операнда
    @reserved_counter = 0 #счётчик полей для резервирования
    make_opcode
    make_f
    change_fields
    change_operands
    histogram
  end

  #рассчитываем шестнадцатиричный код для каждой операции
  def make_opcode
    @json['instructions'].each do |insn|
      t = 0x0
      insn['insns'].each do |op|
        @opcode[op] = t unless insn['operands'].include? 'code'
        t += 0x1
      end
    end
  end

  #рассчитываем коды для форматов
  def make_f
    t = 0
    @json['instructions'].each do |insn|
      @f[insn['format']] ||= t
      t += 1
    end
  end

  #форматы и коды операций вместе с количеством бит для хранения помещаем в изначальный хэш
  def change_fields
    @json['fields'] << { 'F' => @f[@f.to_a.last[0]].to_s(2).split('').count.to_s } unless @f.empty?
    @json['fields'] << { 'OPCODE' => @opcode.sort_by{|k,v| v}.last[1].to_s(2).split('').count.to_s } unless @opcode.empty?
  end

  #также помещаем поля формата и кода в список операндов, с которым потом будем работать
  def change_operands
    @json['instructions'].each do |insn|
      insn['operands'] << 'F'
      insn['operands'] << 'OPCODE' unless insn['operands'].include? 'code'
    end
  end

  #мы хотим знать, сколько раз используется каждый операнд
  #учитывается количество инструкций, которые могут обращаться к операнду
  #т.е. если у нас есть 10 инструкций и 3 операнда, то каждый операнд используется 10 раз
  def histogram
    total_count = 0
    @json['instructions'].each do |insn|
      total_count += insn['insns'].count
      insn['operands'].each do |op|
        if op != 'OPCODE' and op != 'F'
          @histogram[op] ||= 0
          @histogram[op] += insn['insns'].count
        end
      end
    end
    @histogram['OPCODE'] = total_count
    @histogram['F'] = total_count
    @histogram = @histogram.sort_by{|k,v| v}.reverse.to_h #сортируем по убыванию
  end

  #проверяем, содержит ли данный формат такой операнд
  def contains?(format, op)
    @json['instructions'].find{ |insn| insn['format'] == format }['operands'].include? op
  end

  #может так получиться при изначальном распределении бит, что поля пересекаются
  #поэтому сдвигаем правое поле
  #так можно делать только для операндов, которые встречаются только в одном формате
  #потому что иначе может оказаться так, что одинаковые операнды будут находиться в разных местах
  def check_for_less(b)
    b.each do |format, fields|
      fields.each_with_index do |hash, i|
        if i > 0 and @histogram[hash.keys[0]] == 1 and hash.values[0][:msb] <= fields[i-1].values[0][:lsb]
         hash.values[0][:lsb] += fields[i-1].values[0][:lsb] - hash.values[0][:msb] + 1
         hash.values[0][:msb] += fields[i-1].values[0][:lsb] - hash.values[0][:msb] + 1
       end
      end
    end
  end

  #фикс для резервированных полей
  def fix_reserved(b)
    b.each do |format, fields|
      fields.each_with_index do |hash, i|
        if hash.keys[0].include? 'RES' and hash.values[0][:msb] - fields[i-1].values[0][:lsb] > 1
          hash.values[0][:msb] = fields[i-1].values[0][:lsb] + 1
        end
      end
    end
  end

  #фикс для последних полей хэша
  #либо это поле, которое можно удлинить (>=)
  #либо создаем поле RES
  def check_for_last_fields(fields, format)
    if fields.last.values[0][:lsb] < @json['length'].to_integer - 1
      if @json['fields'].find { |field| field.keys.include? fields.last.keys[0] }.values[0].include? '>='
        fields.last.values[0][:lsb] = @json['length'].to_integer - 1
      else
        fields << { "RES#{@reserved_counter}" => {:msb => fields.last.values[0][:lsb] + 1, :lsb => @json['length'].to_integer - 1, :value => '+' } }
        @json['instructions'].find{ |insn| insn['format'] == format }['operands'] << "RES#{@reserved_counter}"
        @reserved_counter += 1
      end
    end
  end

  #собственно биты
  #идея
  #чем чаще используется операнд, тем раньше мы хоим выделить ему место
  #есть отсортированный по убыванию список операндов
  #для каждого формата
  #идём по этому списку, берём самый часто используемый операнд, который есть в этом формате текущий бит - 0
  #создаём диапазон с началом в текущем бите и концом в длине, указанной в json'е
  #сдвигаем текущий бит на длину поля (для полей с ">=" - минимально возможную)
  #повторяем для всех форматов и всех операндов
  #теперь у нас есть хэш, где для каждого формата и операнда лежат возможные диапазоны размещения
  #пересекаем все диапазоны для операнда - получаем его точное расположение
  def make_bits
    ranges = {}
    #создаем диапазоны
    @f.each do |format, f_value|
      current_bit = 0
      @histogram.each do |op, op_value|
        @bits[format] ||= []
        if contains?(format, op)
          ranges[op] ||= []
          @bits[format] << { op => { 'msb': current_bit, 'lsb': @json['length'].to_integer - 1, 'value': '+' } }
          ranges[op] << (current_bit..@json['length'].to_integer - 1)
          current_bit = @bits[format].last.values[0][:msb] + @json['fields'].find { |field| field.keys.include? op }.values[0].to_integer
        end
      end
    end
    #пересекаем диапазоны
    ranges.each do |op, value|
      ar = value.map{ |range| range.to_a }.inject{ |sum, r| sum & r }
      ranges[op] = (ar.first..ar.first + @json['fields'].find { |field| field.keys.include? op }.values[0].to_integer)
    end
    #подчищаем
    @bits.each do |format, fields|
      fields.each_with_index do |hash, i|
        hash.values[0][:msb] = ranges[hash.keys[0]].first
        hash.values[0][:lsb] = ranges[hash.keys[0]].last - 1
        #случай, когда правое поле пересекается с левым
        #надо подвинуть правое
        if i > 0 and @histogram[hash.keys[0]] == 1 and hash.values[0][:msb] <= fields[i-1].values[0][:lsb]
          hash.values[0][:lsb] += fields[i-1].values[0][:lsb] - hash.values[0][:msb] + 1
          hash.values[0][:msb] += fields[i-1].values[0][:lsb] - hash.values[0][:msb] + 1
        end
        #случай, когда образовался разрыв между двумя полями
        if i > 0 and hash.values[0][:msb] - fields[i-1].values[0][:lsb] > 1
          gap = hash.values[0][:msb] - fields[i-1].values[0][:lsb] - 1
          field = @json['fields'].find { |field| field.keys.include? fields[i-1].keys[0] }
          #удлиняем левое поле, если возможно
          if field.values[0].include? '>='
            fields[i-1].values[0][:lsb] += gap
          else
            #либо правее находим такое поле, которое помещается в этот разрыв
            instr = @json['instructions'].find{ |insn| insn['format'] == format }
            if (oper = instr['operands'].find { |op| @json['fields'].find {|f| f.keys.include? op}.values[0].to_integer <= gap and @histogram[op] == 1 })
              to_change = fields.find { |f| f.keys.include? oper }
              to_change.values[0][:msb] = fields[i-1].values[0][:lsb] + 1
              #а вдруг его ещё и удлинить можно
              if @json['fields'].find { |f| f.keys.include? oper }.values[0].include? '>='
                to_change.values[0][:lsb] = hash.values[0][:msb] - 1
              else
                to_change.values[0][:lsb] = to_change.values[0][:msb] + @json['fields'].find { |f| f.keys.include? oper }.values[0].to_integer - 1
              end
            else
              #либо создаем на этом месте резервное поле
              fields << { "RES#{@reserved_counter}" => {:msb => fields[i-1].values[0][:lsb] + 1, :lsb => hash.values[0][:msb] - 1, :value => '+' } }
              instr['operands'] << "RES#{@reserved_counter}"
              @reserved_counter += 1
            end
            #поменяли порядок полей - надо посортить и подчистить
            fields.sort_by!{|h| h.values[0][:msb]}
            check_for_less(@bits)
            fix_reserved(@bits)
          end
        end
      end
      check_for_last_fields(fields, format)
    end
  end

  #создаем json с помощью полученного хэша бит и хэшей со значениями полей
  def make_new_json
    result = []
    make_bits
    @json['instructions'].each do |i|
      i['insns'].each do |instr|
        res = {}
        res['insn'] = instr
        res['fields'] = []
        i['operands'].each do |op|
          h = @bits[i['format']].find { |operand| operand.keys[0].include? op }
          if op == 'F'
            value = @f[i['format']].to_s(2)
          elsif op == 'OPCODE'
            value = @opcode[instr].to_s(2)
          elsif op.include? 'RES'
            value = '0' * (h.values[0][:lsb] - h.values[0][:msb] + 1)
          else
            value = '+'
          end
          res['fields'] << { op.to_sym => {msb: @json['length'].to_integer - h.values[0][:msb] - 1, lsb: @json['length'].to_integer - h.values[0][:lsb] - 1, value: value } }
        end
        res['fields'].sort_by!{|h| h.values[0][:msb]}.reverse!
        result << res
      end
    end
    File.open('out.json', 'w').puts JSON.pretty_generate(result)
  end
end

encoder = Encoder.new(ARGV[0])
encoder.make_new_json