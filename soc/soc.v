/*
Top module for SoC.
*/

module soc(
		input clk48m, 
		input [7:0] btn, 
		output [5:0] led,
		output [27:0] genio,
		output uart_tx,
		input uart_rx,
		output pwmout,
		output [17:0] lcd_db,
		output lcd_rd,
		output lcd_wr,
		output lcd_rs,
		output lcd_cs,
		input lcd_id,
		output lcd_rst,
		input lcd_fmark,
		output lcd_blen,
		output psrama_nce,
		output psrama_sclk,
		input [3:0] psrama_sin,
		output [3:0] psrama_sout,
		output psrama_oe,
		output psramb_nce,
		output psramb_sclk,
		input [3:0] psramb_sin,
		output [3:0] psramb_sout,
		output psramb_oe
	);

	parameter integer MEM_WORDS = 4096;
	parameter [31:0] STACKADDR = (MEM_WORDS*4);
	parameter [31:0] PROGADDR_RESET = 32'h0;
	parameter [31:0] PROGADDR_IRQ = 31'h10;

	reg [5:0] reset_cnt = 0;
	wire resetn = &reset_cnt;
	wire rst = !resetn;
	always @(posedge clk48m) begin
		if (btn[7]) begin
			if (!resetn) reset_cnt <= reset_cnt + 1;
		end else begin
			reset_cnt <= 0;
		end
	end

	wire mem_valid;
	wire mem_instr;
	wire mem_ready;
	wire [31:0] mem_addr;
	wire [31:0] mem_wdata;
	wire [3:0] mem_wstrb;
	reg [31:0] mem_rdata;
	wire [31:0] irq;
	reg [5:0] led;
	reg [7:0] psrama_ovr;
	reg [7:0] psramb_ovr;


/* verilator lint_off PINMISSING */
	picorv32 #(
		.STACKADDR(STACKADDR),
		.PROGADDR_RESET(PROGADDR_RESET),
		.PROGADDR_IRQ(PROGADDR_IRQ),
		.BARREL_SHIFTER(1),
		.COMPRESSED_ISA(1),
		.ENABLE_COUNTERS(0),
		.ENABLE_MUL(1),
		.ENABLE_DIV(1),
		.ENABLE_IRQ(0),
		.ENABLE_IRQ_QREGS(0)
	) cpu (
		.clk         (clk48m     ),
		.resetn      (resetn     ),
		.mem_valid   (mem_valid  ),
		.mem_instr   (mem_instr  ),
		.mem_ready   (mem_ready  ),
		.mem_addr    (mem_addr   ),
		.mem_wdata   (mem_wdata  ),
		.mem_wstrb   (mem_wstrb  ),
		.mem_rdata   (mem_rdata  ),
		.irq         (irq        )
	);
/* verilator lint_on PINMISSING */

	assign irq = 'h0;

	reg mem_select;
	reg uart_div_select;
	reg uart_dat_select;
	reg led_select;
	wire[31:0] ram_rdata;
	wire[31:0] uart_reg_div_do;
	wire[31:0] uart_reg_dat_do;
	wire uart_reg_dat_wait;
	reg ram_ready;
	wire [31:0] lcd_rdata;
	reg lcd_select;
	wire lcd_ready;

	always @(*) begin
		mem_select = 0;
		uart_div_select = 0;
		uart_dat_select = 0;
		led_select = 0;
		lcd_select = 0;
		mem_rdata = 'hDEADBEEF;
		if (mem_addr[31:28]=='h0) begin
			mem_select = mem_valid;
			mem_rdata = ram_rdata;
		end else if (mem_addr[31:28]=='h1) begin
			if (mem_addr[2]==0) begin
				uart_dat_select = mem_valid;
				mem_rdata = uart_reg_dat_do;
			end else begin
				uart_div_select = mem_valid;
				mem_rdata = uart_reg_div_do;
			end
		end else if (mem_addr[31:28]=='h2) begin
			led_select = mem_valid;
			//todo: led/psram/... readback
		end else if (mem_addr[31:28]=='h3) begin
			lcd_select = mem_valid;
			mem_rdata = lcd_rdata;
		end
	end

	assign mem_ready = ram_ready || uart_div_select || led_select || (uart_dat_select && !uart_reg_dat_wait) || lcd_ready;


	lcdiface lcdiface(
		.clk(clk48m),
		.nrst(resetn),
		.addr(mem_addr[4:2]),
		.wen(lcd_select && mem_wstrb==4'b1111),
		.ren(lcd_select && mem_wstrb==4'b0000),
		.rdata(lcd_rdata),
		.wdata(mem_wdata),
		.ready(lcd_ready),

		.lcd_db(lcd_db),
		.lcd_rd(lcd_rd),
		.lcd_wr(lcd_wr),
		.lcd_rs(lcd_rs),
		.lcd_cs(lcd_cs),
		.lcd_id(lcd_id),
		.lcd_rst(lcd_rst),
		.lcd_fmark(lcd_fmark),
		.lcd_blen(lcd_blen)
	);


	simpleuart simpleuart (
		.clk         (clk48m      ),
		.resetn      (resetn      ),

		.ser_tx      (uart_tx    ),
		.ser_rx      (uart_rx      ),

		.reg_div_we  (uart_div_select ? mem_wstrb : 4'b 0000),
		.reg_div_di  (mem_wdata),
		.reg_div_do  (uart_reg_div_do),

		.reg_dat_we  (uart_dat_select ? mem_wstrb[0] : 1'b 0),
		.reg_dat_re  (uart_dat_select && mem_wstrb==0),
		.reg_dat_di  (mem_wdata),
		.reg_dat_do  (uart_reg_dat_do),
		.reg_dat_wait(uart_reg_dat_wait)
	);

	assign genio[27:4]='h0;
	assign genio[2]=clk48m;
	assign genio[3]=uart_rx;

	wire qpi_do_read, qpi_do_write;
	reg qpi_next_byte;
	wire [23:0] qpi_addr;
	reg [31:0] qpi_rdata;
	wire [31:0] qpi_wdata;
	reg qpi_is_idle;

	qpimem_cache #(
		.CACHELINE_WORDS(8),
		.CACHELINE_CT(32),
		.ADDR_WIDTH(22) //addresses words
	) qpimem_cache (
		.clk(clk48m),
		.rst(rst),
		
		.qpi_do_read(qpi_do_read),
		.qpi_do_write(qpi_do_write),
		.qpi_next_byte(qpi_next_byte),
		.qpi_addr(qpi_addr),
		.qpi_wdata(qpi_wdata),
		.qpi_rdata(qpi_rdata),
		.qpi_is_idle(qpi_is_idle),
	
		.wen((mem_valid && !mem_ready && mem_select) ? mem_wstrb : 4'b0),
		.ren(mem_valid && !mem_ready && mem_select && mem_wstrb==0),
		.addr(mem_addr[23:2]),
		.wdata(mem_wdata),
		.rdata(ram_rdata),
		.ready(ram_ready)
	);

	wire qpsrama_sclk;
	wire qpsrama_nce;
	wire [3:0] qpsrama_sout;
	wire qpsrama_oe;

	qpimem_iface qpimem_iface(
		.clk(clk48m),
		.rst(rst),
		
		.do_read(qpi_do_read),
		.do_write(qpi_do_write),
		.next_byte(qpi_next_byte),
		.addr(qpi_addr),
		.wdata(qpi_wdata),
		.rdata(qpi_rdata),
		.is_idle(qpi_is_idle),

		.spi_clk(qpsrama_sclk),
		.spi_ncs(qpsrama_nce),
		.spi_sout(qpsrama_sout),
		.spi_sin(psrama_sin),
		.spi_oe(qpsrama_oe)
	);

	wire psrama_override;
	assign psrama_override=psrama_ovr[7];
	assign psrama_oe = psrama_override ? psrama_ovr[6] : qpsrama_oe;
	assign psrama_sclk = psrama_override ? psrama_ovr[5] : qpsrama_sclk;
	assign psrama_nce = psrama_override ? psrama_ovr[4] : qpsrama_nce;
	assign psrama_sout = psrama_override ? psrama_ovr[3:0] : qpsrama_sout;

	always @(posedge clk48m) begin
		if (rst) begin
			led <= 0;
			psrama_ovr <= 0;
			psramb_ovr <= 0;
		end else if (led_select && mem_wstrb[0]) begin
			if (mem_addr[4:2]==0) begin
				led <= mem_wdata[5:0];
			end else if (mem_addr[4:2]==1) begin
				psrama_ovr <= mem_wdata;
			end else if (mem_addr[4:2]==2) begin
				psramb_ovr <= mem_wdata;
			end
		end
	end
	
	//Unused pins
	assign pwmout = 0;
	assign psramb_sclk = 0;
	assign psramb_nce = 0;
	assign psramb_sclk = 0;
	assign psramb_oe = 0;
	assign psramb_sout = 0;
	assign genio[0] = 0;
	assign genio[1] = 0;
	
	
endmodule
