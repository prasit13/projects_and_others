module stageInstFetch (
    input logic clk,
    input logic rst,

    input logic bPredictTaken,
    input logic usePredictor,
    input logic pcSelE,
    input logic wrongBranchE,
    input logic stall,
    input logic [31:0] btbTarget,
    input logic [31:0] pcTargetE,
    // N4: the perceptron's late verdict overrules the fast fetch prediction
    input logic ovrValid,
    input logic [31:0] ovrTarget,

    output logic [31:0] imemAddr,
    input logic [31:0] imemData,

    output logic [31:0] instr,
    output logic [31:0] pcPlus4,
    output logic [31:0] pc,
    output logic bPredictedTaken
  );

  logic [31:0] pc_;

  assign pcPlus4 = pc + 4;
  assign imemAddr = pc;
  assign instr = imemData; //imm data
  assign bPredictedTaken = usePredictor&bPredictTaken;

  // Redirect priority:
  //   1. EX resolved a misprediction   -- oldest instruction, always wins
  //   2. the perceptron overrode DECODE's fast prediction (N4)
  //   3. the fast BTB prediction says taken
  //   4. fall through
  always_comb
  begin
    if(usePredictor)
    begin
      if (wrongBranchE)
        pc_ = pcTargetE;
      else if (ovrValid)
        pc_ = ovrTarget;
      else if (bPredictTaken)
        pc_ = btbTarget;
      else
        pc_ = pcPlus4;
    end
    else
      pc_ = pcSelE?pcTargetE:pcPlus4;
  end



  always_ff@(posedge clk)
  begin
    if (rst)
    begin
      pc <= 0;
    end
    else
    begin
      if (!stall)
      begin : PCreg
        pc <= pc_;
      end
    end
  end
endmodule
