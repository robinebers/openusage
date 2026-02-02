import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Progress } from "@/components/ui/progress"
import { Separator } from "@/components/ui/separator"
import { Skeleton } from "@/components/ui/skeleton"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"

describe("ui components", () => {
  it("renders alert variants", () => {
    render(
      <Alert variant="destructive">
        <AlertDescription>Danger</AlertDescription>
      </Alert>
    )
    expect(screen.getByRole("alert")).toHaveTextContent("Danger")
  })

  it("renders badge variants", () => {
    render(
      <>
        <Badge variant="default">Default</Badge>
        <Badge variant="outline">Outline</Badge>
      </>
    )
    expect(screen.getByText("Default")).toBeInTheDocument()
    expect(screen.getByText("Outline")).toBeInTheDocument()
  })

  it("renders button variants", () => {
    render(
      <>
        <Button>Default</Button>
        <Button variant="outline" size="icon-xs">O</Button>
      </>
    )
    expect(screen.getByRole("button", { name: "Default" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "O" })).toBeInTheDocument()
  })

  it("renders checkbox", () => {
    render(<Checkbox checked={false} onCheckedChange={() => {}} />)
    expect(screen.getByRole("checkbox")).toBeInTheDocument()
  })

  it("renders progress with clamp + custom color", () => {
    const { rerender } = render(<Progress value={150} indicatorColor="#fff" />)
    expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "100")
    rerender(<Progress value={-5} />)
    expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "0")
  })

  it("renders separator orientations", () => {
    const { rerender } = render(<Separator />)
    expect(screen.getByRole("separator")).toBeInTheDocument()
    rerender(<Separator orientation="vertical" />)
    expect(screen.getByRole("separator")).toHaveAttribute("data-orientation", "vertical")
  })

  it("renders skeleton", () => {
    render(<Skeleton data-testid="skeleton" />)
    expect(screen.getByTestId("skeleton")).toBeInTheDocument()
  })

  it("renders tabs + content", () => {
    render(
      <Tabs value="one">
        <TabsList variant="line">
          <TabsTrigger value="one">One</TabsTrigger>
        </TabsList>
        <TabsContent value="one">Tab content</TabsContent>
      </Tabs>
    )
    expect(screen.getByText("One")).toBeInTheDocument()
    expect(screen.getByText("Tab content")).toBeInTheDocument()
  })

  it("renders tooltip content when open", () => {
    render(
      <Tooltip open>
        <TooltipTrigger>Trigger</TooltipTrigger>
        <TooltipContent>Tip</TooltipContent>
      </Tooltip>
    )
    expect(screen.getByText("Tip")).toBeInTheDocument()
  })
})
