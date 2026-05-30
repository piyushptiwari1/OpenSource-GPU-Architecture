`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION DECODER
// > Decodes an instruction into the control signals necessary to execute it
// > Each core has it's own decoder
module decoder (
    input wire clk,
    input wire reset,

    input [2:0] core_state,
    input [15:0] instruction,
    
    // Instruction Signals
    output reg [3:0] decoded_rd_address,
    output reg [3:0] decoded_rs_address,
    output reg [3:0] decoded_rt_address,
    output reg [2:0] decoded_nzp,
    output reg [7:0] decoded_immediate,
    
    // Control Signals
    output reg decoded_reg_write_enable,           // Enable writing to a register
    output reg decoded_mem_read_enable,            // Enable reading from memory
    output reg decoded_mem_write_enable,           // Enable writing to memory
    output reg decoded_nzp_write_enable,           // Enable writing to NZP register
    output reg [1:0] decoded_reg_input_mux,        // Select input to register
    output reg [1:0] decoded_alu_arithmetic_mux,   // Select arithmetic operation
    output reg decoded_alu_output_mux,             // Select operation in ALU
    output reg decoded_pc_mux,                     // Select source of next PC

    // Atomic op selector for the LSU. Only meaningful when both
    // decoded_mem_read_enable and decoded_mem_write_enable are 1.
    //   0 = ATOMICADD : mem[Rs] <- mem[Rs] + Rt
    //   1 = ATOMICCAS : if mem[Rs] == 0 then mem[Rs] <- Rt
    output reg decoded_atomic_op,

    // Block-wide barrier (BAR). From the datapath's point of view this is a
    // no-op (PC+1, no reg/mem/branch); the synchronisation is handled by the
    // scheduler, which holds every arriving lane until all live lanes have
    // reached the barrier before releasing them together.
    output reg decoded_barrier,

    // Shared-memory address space selector (LDS/STS). When high, the LSU steers
    // its memory request to the core-local banked shared_memory.sv island
    // instead of the global data-memory controller. Only meaningful when one of
    // mem_read_enable / mem_write_enable is also asserted.
    output reg decoded_shared,

    // Return (finished executing thread)
    output reg decoded_ret
);
    localparam NOP = 4'b0000,
        BRnzp = 4'b0001,
        CMP = 4'b0010,
        ADD = 4'b0011,
        SUB = 4'b0100,
        MUL = 4'b0101,
        DIV = 4'b0110,
        LDR = 4'b0111,
        STR = 4'b1000,
        CONST = 4'b1001,
        ATOMICADD = 4'b1010,
        ATOMICCAS = 4'b1011,
        BAR = 4'b1100,
        LDS = 4'b1101,
        STS = 4'b1110,
        RET = 4'b1111;

    always @(posedge clk) begin 
        if (reset) begin 
            decoded_rd_address <= 0;
            decoded_rs_address <= 0;
            decoded_rt_address <= 0;
            decoded_immediate <= 0;
            decoded_nzp <= 0;
            decoded_reg_write_enable <= 0;
            decoded_mem_read_enable <= 0;
            decoded_mem_write_enable <= 0;
            decoded_nzp_write_enable <= 0;
            decoded_reg_input_mux <= 0;
            decoded_alu_arithmetic_mux <= 0;
            decoded_alu_output_mux <= 0;
            decoded_pc_mux <= 0;
            decoded_atomic_op <= 0;
            decoded_barrier <= 0;
            decoded_shared <= 0;
            decoded_ret <= 0;
        end else begin 
            // Decode when core_state = DECODE
            if (core_state == 3'b010) begin 
                // Get instruction signals from instruction every time
                decoded_rd_address <= instruction[11:8];
                decoded_rs_address <= instruction[7:4];
                decoded_rt_address <= instruction[3:0];
                decoded_immediate <= instruction[7:0];
                decoded_nzp <= instruction[11:9];

                // Control signals reset on every decode and set conditionally by instruction
                decoded_reg_write_enable <= 0;
                decoded_mem_read_enable <= 0;
                decoded_mem_write_enable <= 0;
                decoded_nzp_write_enable <= 0;
                decoded_reg_input_mux <= 0;
                decoded_alu_arithmetic_mux <= 0;
                decoded_alu_output_mux <= 0;
                decoded_pc_mux <= 0;
                decoded_atomic_op <= 0;
                decoded_barrier <= 0;
                decoded_shared <= 0;
                decoded_ret <= 0;

                // Set the control signals for each instruction
                case (instruction[15:12])
                    NOP: begin 
                        // no-op
                    end
                    BRnzp: begin 
                        decoded_pc_mux <= 1;
                    end
                    CMP: begin 
                        decoded_alu_output_mux <= 1;
                        decoded_nzp_write_enable <= 1;
                    end
                    ADD: begin 
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b00;
                    end
                    SUB: begin 
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b01;
                    end
                    MUL: begin 
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b10;
                    end
                    DIV: begin 
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b00;
                        decoded_alu_arithmetic_mux <= 2'b11;
                    end
                    LDR: begin 
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b01;
                        decoded_mem_read_enable <= 1;
                    end
                    STR: begin 
                        decoded_mem_write_enable <= 1;
                    end
                    CONST: begin 
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b10;
                    end
                    ATOMICADD: begin
                        // Read-modify-write on mem[Rs]; Rd <- old value,
                        // mem[Rs] <- old + Rt. The LSU recognises both
                        // mem_*_enable being asserted and runs its
                        // 5-phase atomic FSM (REQ_R → WAIT_R → REQ_W
                        // → WAIT_W → DONE) instead of the normal
                        // single-shot path.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b01;
                        decoded_mem_read_enable <= 1;
                        decoded_mem_write_enable <= 1;
                        decoded_atomic_op <= 0;
                    end
                    ATOMICCAS: begin
                        // Test-and-set on mem[Rs]: if old == 0 then
                        // mem[Rs] <- Rt; Rd <- old. Reuses the LSU's
                        // atomic FSM via the decoded_atomic_op selector.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b01;
                        decoded_mem_read_enable <= 1;
                        decoded_mem_write_enable <= 1;
                        decoded_atomic_op <= 1;
                    end
                    BAR: begin
                        // Datapath no-op; scheduler performs the block-wide
                        // synchronisation based on decoded_barrier.
                        decoded_barrier <= 1;
                    end
                    LDS: begin
                        // Load from per-block shared memory: Rd <- shmem[Rs].
                        // Same control vector as LDR plus decoded_shared so the
                        // LSU routes the request to the shared-memory island.
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux <= 2'b01;
                        decoded_mem_read_enable <= 1;
                        decoded_shared <= 1;
                    end
                    STS: begin
                        // Store to per-block shared memory: shmem[Rs] <- Rt.
                        decoded_mem_write_enable <= 1;
                        decoded_shared <= 1;
                    end
                    RET: begin 
                        decoded_ret <= 1;
                    end
                endcase
            end
        end
    end
endmodule
