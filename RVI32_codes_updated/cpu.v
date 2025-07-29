/* 
====================================
RISC-V CPU Core
FSM-based CPU supporting:
- R-type, I-type, B-type, JAL, JALR, LUI, AUIPC
- Loads and Stores (Word, Byte, Halfword)
- Shifts (SLL, SRL), Arithmetic shift (SRA)
- Branching logic
- Program counter and register file
====================================
*/

module cpu(
    input rst, clk,                    // Reset and clock signals
    input [31:0] mem_rdata,            // Data read from memory (e.g., instruction or load)
    output [31:0] mem_addr,            // Address to memory (instruction/data)
    output [31:0] mem_wdata,           // Data to be written to memory
    output mem_rstrb,                  // Read strobe (for instruction/data fetch)
    output reg [31:0] cycle,           // Cycle counter (for stats/debug)
    output [3:0] mem_wstrb             // Write strobe (byte-mask)
);

  // ---------------------------------------
  // === REGISTER FILE & CONTROL SIGNALS ===
  // ---------------------------------------
  reg [31:0] regfile[0:31];            // 32 registers (x0 to x31)
  reg [31:0] addr, data_rs1, data_rs2; // Program counter and ALU sources
  reg [31:0] data;                     // Instruction latch
  reg [3:0] state;                     // FSM current state

  // FSM state encoding
  parameter RESET = 0, WAIT = 1, FETCH = 2, DECODE = 3, 
            EXECUTE = 4, BYTE = 5, WAIT_LOADING = 6, HLT = 7;

  // -------------------------------
  // === INSTRUCTION DECODING ===
  // -------------------------------
  wire [4:0] opcode = data[6:2];
  wire [4:0] rd = data[11:7];
  wire [2:0] funct3 = data[14:12];
  wire [6:0] funct7 = data[31:25];

  // Immediate generators (sign-extended)
  wire [31:0] I_data = {{21{data[31]}}, data[30:20]};
  wire [31:0] S_data = {{21{data[31]}}, data[30:25], data[11:7]};
  wire [31:0] B_data = {{20{data[31]}}, data[7], data[30:25], data[11:8], 1'b0};
  wire [31:0] J_data = {{12{data[31]}}, data[19:12], data[20], data[30:21], 1'b0};
  wire [31:0] U_data = {data[31:12], 12'h000};

  // Instruction type checks
  wire isRtype  = (opcode == 5'b01100);
  wire isItype  = (opcode == 5'b00100);
  wire isBtype  = (opcode == 5'b11000);
  wire isStype  = (opcode == 5'b01000);
  wire isLtype  = (opcode == 5'b00000);
  wire isSystype= (opcode == 5'b11100);
  wire isJAL    = (opcode == 5'b11011);
  wire isJALR   = (opcode == 5'b11001);
  wire isLUI    = (opcode == 5'b01101);
  wire isAUIPC  = (opcode == 5'b00101);

  // -----------------------------
  // === ALU OPERATIONS ===
  // -----------------------------
  wire [31:0] alu_in1 = data_rs1;
  wire [31:0] alu_in2 = (isRtype | isBtype) ? data_rs2 :
                        (isItype | isLtype | isJALR) ? I_data :
                        S_data;

  wire [32:0] SUB = {1'b0, alu_in1} + {1'b1, ~alu_in2} + 1'b1;
  wire [31:0] ADD = alu_in1 + alu_in2;
  wire [31:0] XOR = alu_in1 ^ alu_in2;
  wire [31:0] OR  = alu_in1 | alu_in2;
  wire [31:0] AND = alu_in1 & alu_in2;

  // Shift logic (SLL, SRL, SRA)
  wire [31:0] shift_amt = isRtype ? alu_in2 : {27'b0, alu_in2[4:0]};
  wire [31:0] SLL = alu_in1 << shift_amt;
  wire [31:0] SRL = alu_in1 >> shift_amt;
  wire [31:0] SRA = $signed(alu_in1) >>> shift_amt;

  // Branch logic
  wire EQUAL        = (SUB[31:0] == 0);
  wire NEQUAL       = !EQUAL;
  wire LESS_THAN    = (alu_in1[31] ^ alu_in2[31]) ? alu_in1[31] : SUB[32];
  wire LESS_THAN_U  = SUB[32];
  wire GREATER_THAN = !LESS_THAN;
  wire GREATER_THAN_U = !LESS_THAN_U;

  wire TAKE_BRANCH = ((funct3==3'b000) & EQUAL) |
                     ((funct3==3'b001) & NEQUAL) |
                     ((funct3==3'b100) & LESS_THAN) |
                     ((funct3==3'b101) & GREATER_THAN) |
                     ((funct3==3'b110) & LESS_THAN_U) |
                     ((funct3==3'b111) & GREATER_THAN_U);

  // ALU result selection based on instruction
  wire [31:0] alu_result = (funct3==3'b000 && isRtype && ~funct7[5]) ? ADD :
                           (funct3==3'b000 && isItype)               ? ADD :
                           (funct3==3'b000 && ~isLtype && funct7[5]) ? SUB[31:0] :
                           (funct3==3'b100) ? XOR :
                           (funct3==3'b110) ? OR :
                           (funct3==3'b111) ? AND :
                           (funct3==3'b010 && ~isLtype) ? {31'b0, LESS_THAN} :
                           (funct3==3'b011) ? {31'b0, LESS_THAN_U} :
                           (funct3==3'b001 && ~isStype) ? SLL :
                           (funct3==3'b101 && ~funct7[5]) ? SRL :
                           (funct3==3'b101 && funct7[5]) ? SRA :
                           (isStype | isLtype | isJALR) ? ADD : 32'b0;

  // -------------------------------
  // === LOAD / STORE HANDLING ===
  // -------------------------------
  wire [31:0] pcplus4 = addr + 4;
  wire [31:0] pcplusimm = addr + (isBtype ? B_data : isJAL ? J_data : isAUIPC ? U_data : 0);

  // Load data formatting (sign/zero extended)
  wire load_flag = (state == BYTE || state == WAIT_LOADING);
  wire [31:0] load_store_addr = load_flag ? alu_result : 0;

  wire mem_byteAccess     = (data[13:12] == 2'b00); // LB
  wire mem_halfwordAccess = (data[13:12] == 2'b01); // LH

  wire [15:0] LOAD_halfword = load_store_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];
  wire [7:0]  LOAD_byte = load_store_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];
  wire LOAD_sign = !data[14] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);

  wire [31:0] load_data_tmp = mem_byteAccess     ? {{24{LOAD_sign}}, LOAD_byte} :
                              mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                              mem_rdata;

  // Write mask for STORE (byte/halfword/word)
  wire [3:0] STORE_wmask = mem_byteAccess ? 
                            (load_store_addr[1] ? (load_store_addr[0] ? 4'b1000 : 4'b0100) :
                                                  (load_store_addr[0] ? 4'b0010 : 4'b0001)) :
                            mem_halfwordAccess ?
                            (load_store_addr[1] ? 4'b1100 : 4'b0011) : 4'b1111;

  assign mem_wstrb = {4{(state == WAIT_LOADING) & isStype}} & STORE_wmask;
  assign mem_addr  = ((isStype | isLtype) && load_flag) ? load_store_addr : addr;
  assign mem_rstrb = (state == WAIT) || (isLtype && load_flag);

  // ---------------------------------------------------
  // DEBUG: print every time we think we're doing a store
  // ---------------------------------------------------
  always @(posedge clk) begin
    // WAIT_LOADING is where we actually drive the write
    if (state == WAIT_LOADING && isStype) begin
      $display("CPU STORE @ time %0t:", $time);
      $display("  state       = %0d", state);
      $display("  isStype     = %b", isStype);
      $display("  mem_addr    = %08h", mem_addr);
      $display("  STORE_mask  = %b", STORE_wmask);
      $display("  mem_wstrb   = %b", mem_wstrb);
      $display("  mem_wdata   = %08h", mem_wdata);
    end
  end



  // Write data generation for STORE
  assign mem_wdata[ 7: 0] = data_rs2[7:0];
  assign mem_wdata[15: 8] = load_store_addr[0] ? data_rs2[7:0] : data_rs2[15:8];
  assign mem_wdata[23:16] = load_store_addr[1] ? data_rs2[7:0] : data_rs2[23:16];
  assign mem_wdata[31:24] = load_store_addr[0] ? data_rs2[7:0] :
                            load_store_addr[1] ? data_rs2[15:8] : data_rs2[31:24];

  // --------------------------
  // === INITIALIZATION ===
  // --------------------------
  initial begin
    cycle = 0;
    state = RESET;
    addr = 0;
    regfile[0] = 0;
  end

  // -----------------------------
  // === MAIN FSM EXECUTION ===
  // -----------------------------
  always @(posedge clk) begin
    if (rst) begin
      addr <= 0;
      state <= RESET;
      data <= 0;
    end else begin
      case (state)
        RESET: state <= WAIT;
        WAIT:  state <= FETCH;
        FETCH: begin
          data <= mem_rdata;
          state <= DECODE;
        end
        DECODE: begin
          data_rs1 <= regfile[data[19:15]];
          data_rs2 <= regfile[data[24:20]];
          state <= isSystype ? HLT : EXECUTE;
        end
        EXECUTE: begin
          addr <= (isBtype && TAKE_BRANCH) || isJAL ? pcplusimm :
                  isJALR ? alu_result : pcplus4;
          state <= (isStype | isLtype | isJAL | isJALR) ? BYTE : WAIT;
        end
        BYTE: state <= WAIT_LOADING;
        WAIT_LOADING: state <= WAIT;
      endcase
    end
  end

  // ----------------------------
  // === CYCLE COUNTER ===
  // ----------------------------
  always @(posedge clk) begin
    if (rst)
      cycle <= 0;
    else if (state != HLT)
      cycle <= cycle + 1;
  end

  // -------------------------------
  // === REGISTER WRITE BACK ===
  // -------------------------------
  wire write_reg_en = ((isItype | isRtype | isJAL | isJALR | isLUI | isAUIPC) && (state == EXECUTE)) ||
                      (isLtype && (state == WAIT_LOADING));

  wire [31:0] write_reg_data = (isItype | isRtype) ? alu_result :
                               isLtype ? load_data_tmp :
                               (isJAL | isJALR) ? pcplus4 :
                               isLUI ? U_data :
                               isAUIPC ? pcplusimm : 0;

  always @(posedge clk) begin
    if (write_reg_en && rd != 0)
      regfile[rd] <= write_reg_data;
  end

endmodule
