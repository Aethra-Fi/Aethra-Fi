import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex select-none items-center justify-center gap-2 whitespace-nowrap rounded-sm font-mono text-button font-medium uppercase transition-ui disabled:pointer-events-none disabled:opacity-40 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-fg hover:bg-primary-hover hover:shadow-glow active:bg-primary-active",
        secondary: "border border-border-strong bg-transparent text-fg hover:border-primary hover:text-primary-text",
        outline: "border border-border-strong bg-transparent text-fg hover:border-primary hover:text-primary-text",
        ghost: "text-fg-2 hover:bg-surface-2 hover:text-fg",
        destructive: "border border-danger/60 bg-danger-soft text-danger hover:border-danger",
        link: "h-auto px-0 text-primary-text underline-offset-4 hover:underline",
      },
      size: {
        default: "h-10 px-4",
        sm: "h-8 px-3 text-[11px]",
        lg: "h-12 px-6",
        icon: "h-9 w-9 px-0",
        "icon-sm": "h-8 w-8 px-0",
      },
    },
    compoundVariants: [{ variant: "ghost", size: "default", className: "h-8 px-3" }],
    defaultVariants: { variant: "default", size: "default" },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, type, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    return (
      <Comp
        className={cn(buttonVariants({ variant, size, className }))}
        ref={ref}
        {...(asChild ? {} : { type: type ?? "button" })}
        {...props}
      />
    );
  },
);
Button.displayName = "Button";

export { Button, buttonVariants };
