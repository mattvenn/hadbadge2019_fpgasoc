`default_nettype none
/*
 * Copyright (C) 2019  Jeroen Domburg <jeroen@spritesmods.com>
 * All rights reserved.
 *
 * BSD 3-clause, see LICENSE.bsd
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the <organization> nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


/*
This is an arbiter that allows multiple masters speaking the de-facto SOC memory protocol to 
talk to one memory bus. This protocol is like this:
- Master sets up address and (if needed) wdata, raises either ren or one or more wen lines
- Slave processes what it needs to process, and raises tready as soon as it is done (can 
  be combinatorial, same cycle)
- Slave lowers ready combinatorially if it's not selected (wen/ren is all 0) anymore.

ToDo: is 'ready' defined as such that we can assume that if r/w is asserted the clock after,
that this is a new request? Otherwise, we need three cycles minimum: setup r/w, assert ready, idle.
(At the moment, we wait until ren/wen is deasserted before switching devices, implying a 3-cycle
memory access.)

ToDo: For pipelining, we should allow a new request to somehow be slotted into the acknowledge
cycle... for now, we just allow half the bandwidth to masters (by needing both a request and
acknowledge cycle) and hope the slack is picked up by distributing all bandwidth over multiple
masters.
*/

/*
Note: Verilog-2005 (and Yosys, at this time of writing) do not support arrays as ports. Instead, we pack
n m-sized arrays into one n*m-sized array.
*/

module arbiter #(
	parameter integer MASTER_IFACE_CNT = 2
) (
	input clk, reset,
	input [32*MASTER_IFACE_CNT-1:0] addr,
	input [32*MASTER_IFACE_CNT-1:0] wdata,
	output reg [32*MASTER_IFACE_CNT-1:0] rdata,
	input [MASTER_IFACE_CNT-1:0] valid,
	input [4*MASTER_IFACE_CNT-1:0] wen,
	output reg [MASTER_IFACE_CNT-1:0] ready,
	output [31:0] currmaster,
	
	output reg [31:0] s_addr,
	output reg [31:0] s_wdata,
	input [31:0] s_rdata,
	output reg s_valid,
	output reg [3:0] s_wen,
	input s_ready
);

/*
The connected masters are priority-encoded by index; higher index = higher prio. We can do something more fanciful later
(round-robin, fractional priority, ...) but for now this is simple and stupid.
*/


`ifdef verilator
genvar i;
`else
integer i;
`endif


`define SLICE_32(v, i) v[32*i+:32]
`define SLICE_4(v, i) v[4*i+:4]

reg idle;
reg [$clog2(MASTER_IFACE_CNT)-1:0] active_iface;
reg hold;		//if 1, hold_iface is permanently routed to slave iface
reg [$clog2(MASTER_IFACE_CNT)-1:0] hold_iface;

assign currmaster = hold_iface;

always @(*) begin
	idle=1;
	active_iface=0;
	for (i=0; i<MASTER_IFACE_CNT; i=i+1) begin : genblk
		`SLICE_32(rdata, i)=s_rdata; //no need to mux this
		if ((hold && (hold_iface==i)) || ((!hold) && (valid[i]))) begin
			idle=0;
			active_iface=i;
		end
	end
	ready=0;
	s_addr=`SLICE_32(addr, active_iface);
	s_wdata=`SLICE_32(wdata,  active_iface);
	s_valid=valid[active_iface];
	s_wen=`SLICE_4(wen, active_iface);
	//Note: verilator complains about some circular dependency because of this line... no clue what it's on about.
	if (!idle) ready[active_iface]=s_ready;
//	if (hold) ready[hold_iface]=s_ready;
end

always @(posedge clk) begin
	if (reset) begin
		hold <= 0;
		hold_iface <= 0;
	end else begin
		if (hold && !valid[hold_iface]) begin
			//Read/write is done; un-hold
			hold <= 0;
		end else if (!idle) begin //note: idle is also 0 if hold was set last run
			//We're serving a device.
			hold <= 1;
			hold_iface <= active_iface;
		end else begin
			hold <= 0;
		end
	end
end

`ifdef FORMAL
reg f_past_valid = 0;
reg [7:0] f_slave_ready_low = 0;
reg [7:0] f_transitions = 0;

always @(posedge clk) begin
    f_past_valid <= 1;

    // assume well behaved masters: if waiting for a write then don't de-assert valid and don't change addr, data or wen lines
	for (i=0; i<MASTER_IFACE_CNT; i=i+1) begin
        if(f_past_valid)
            if($past(reset))
                assume(valid == 0);
            else if($past(valid[i]) && $past(~ready[i])) begin
                assume($stable(valid[i]));
                assume($stable(`SLICE_32(addr,i))); 
                assume($stable(`SLICE_32(wdata,i)));
                assume($stable(`SLICE_4(wen,i)));
            end
    end

    // assume well behaved slave doesn't hold ready low for longer than x counts
    if(!s_ready)
        f_slave_ready_low <= f_slave_ready_low + 1;
    assume(f_slave_ready_low < 8);

    // if slave indicates data ready to read then it shouldn't change the data
    if(f_past_valid)
        if($past(s_ready))
            assume($stable(s_rdata)); 
   
    // at reset
    if(!f_past_valid || $past(reset)) begin
	   assume(valid == 0);
    	   assert(s_valid == 0);
    end
    
    // slave valid line can only be asserted if master signals are asserted
    if(valid == 0)
	    assert(s_valid == 0);

    // assert pass through works
    if(valid) begin
        assert(s_addr == `SLICE_32(addr, active_iface));
        assert(s_wdata == `SLICE_32(wdata, active_iface));
        assert(s_valid == valid[active_iface]);
        assert(s_wen == `SLICE_4(wen, active_iface));
    end

    // assert that transition won't happen when one master has control
	for (i=0; i<MASTER_IFACE_CNT; i=i+1) begin
        if(f_past_valid && $past(!reset))
            if( $past(active_iface == i) && $past(valid[i]))
                assert($stable(active_iface));
    end

    // cover a transition
    if(f_past_valid)
        cover($past(valid[1] == 1) && valid[0] == 1);

    // cover both masters wanting to write
    cover(valid[0] && valid[1]);

    // cover throughput
    if(f_past_valid)
        if(valid && $past(active_iface) != active_iface)
            f_transitions <= f_transitions + 1;
    cover(f_transitions == 9);
end
`endif
endmodule
